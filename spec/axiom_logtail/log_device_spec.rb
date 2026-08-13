# frozen_string_literal: true

# These specs lock the Axiom wire contract and the redaction behaviour.
#
# Every wire assertion corresponds to a real failure observed against live Axiom,
# each of which returned a plausible-looking success while doing the wrong thing:
#
#   * /v1/datasets/<ds>/ingest returned 404, and the gem reported success
#   * api.axiom.co returned 400 "must use the edge deployment domain"
#   * omitting ?timestamp-field=dt made Axiom stamp every event at ingest time,
#     returning 200 "ingested":1 while silently discarding the real timestamp
#
# `build_request` is a PRIVATE method of the parent gem. That coupling is the
# point: if an upgrade changes it, these fail in CI rather than silently breaking
# delivery.
RSpec.describe AxiomLogtail::LogDevice do
  subject(:device) { described_class.new('xaat-test-token', 'example-dataset') }

  let(:entry) do
    Logtail::LogEntry.new(:info, Time.utc(2026, 8, 13, 7, 25, 49), nil, 'hello', {}, nil)
  end

  let(:request) { device.send(:build_request, [entry]) }

  describe 'the ingest path' do
    it 'posts to /v1/ingest/<dataset>' do
      expect(request.path).to start_with('/v1/ingest/example-dataset')
    end

    it 'does not use the /v1/datasets/<dataset>/ingest form, which 404s' do
      expect(request.path).not_to include('/v1/datasets/')
    end

    it 'sets timestamp-field=dt so Axiom does not stamp events at ingest time' do
      expect(request.path).to include('timestamp-field=dt')
    end
  end

  describe 'the payload' do
    it 'sends JSON' do
      expect(request['Content-Type']).to eq('application/json')
    end

    it 'sends a JSON array of events carrying dt' do
      body = JSON.parse(request.body)

      expect(body).to be_an(Array)
      expect(body.first).to include('message' => 'hello', 'level' => 'info')
      expect(body.first['dt']).not_to be_nil
    end

    it 'authenticates with a Bearer token' do
      expect(request['Authorization']).to eq('Bearer xaat-test-token')
    end
  end

  describe 'region handling' do
    it 'targets the edge host, never api.axiom.co, which rejects ingest' do
      expect(described_class.edge_host_for('eu-central-1')).to eq('eu-central-1.aws.edge.axiom.co')
      expect(described_class::EDGE_HOSTS.values).not_to include('api.axiom.co')
    end

    it 'raises on an unknown region rather than silently picking a default' do
      expect { described_class.edge_host_for('mars-north-1') }
        .to raise_error(described_class::UnknownRegion, /mars-north-1/)
    end
  end

  describe 'dataset validation' do
    it 'rejects a name that would corrupt the request path' do
      expect { described_class.new('xaat-t', 'bad?name') }
        .to raise_error(described_class::InvalidDataset)
    end
  end

  describe 'buffer bounds' do
    # The queue DROPS when full rather than blocking, and records nothing when it
    # does. Under-sizing it loses log lines invisibly.
    it "matches the parent gem's batch size and queue depth" do
      reference = Logtail::LogDevices::HTTP.new('reference-token')

      expect(device.instance_variable_get(:@batch_size))
        .to eq(reference.instance_variable_get(:@batch_size))
      expect(device.instance_variable_get(:@request_queue).instance_variable_get(:@max_size))
        .to eq(reference.instance_variable_get(:@request_queue).instance_variable_get(:@max_size))
    end

    # Back pressure would block #write, which runs on the request path, turning a
    # slow sink into an application outage. Dropping is correct -- which is why
    # the bound has to be generous.
    it 'drops rather than blocking when the queue fills' do
      expect(device.instance_variable_get(:@request_queue))
        .to be_a(Logtail::LogDevices::HTTP::FlushableDroppingSizedQueue)
    end
  end

  # These fixtures are STRING-shaped on purpose. Apps do not emit nested hashes
  # for headers_json / params_json -- they emit a JSON document serialised into a
  # string. An earlier version of this redaction walked only Hash and Array,
  # every unit spec built its fixtures as nested hashes, every example passed,
  # and live Basic-auth credentials shipped to a third party.
  describe 'redaction inside serialised JSON, the shape apps actually emit' do
    let(:entry) do
      Logtail::LogEntry.new(
        :info, Time.utc(2026, 8, 13), nil, 'req',
        {
          event: {
            http_request_received: {
              headers_json: '{"Authorization":"Basic ZGVwbG95OnNlY3JldA==",' \
                            '"Cookie":"_session=SESSIONSECRET",' \
                            '"User_Agent":"Mozilla/5.0","Host":"example.com"}',
              path: '/projects.json'
            }
          }
        },
        nil
      )
    end

    let(:body) { request.body }

    it 'redacts credentials nested inside a serialised JSON string' do
      expect(body).not_to include('ZGVwbG95OnNlY3JldA==')
      expect(body).not_to include('SESSIONSECRET')
    end

    it 'keeps non-sensitive fields readable' do
      expect(body).to include('Mozilla/5.0')
      expect(body).to include('/projects.json')
    end
  end

  describe 'redaction of structured keys' do
    let(:entry) do
      Logtail::LogEntry.new(:info, Time.utc(2026, 8, 13), nil, 'x',
                            { context: { authorization: 'Bearer SECRET', email: 'user@example.com', host: 'example.com' } },
                            nil)
    end

    it 'redacts credential keys' do
      expect(request.body).not_to include('SECRET')
    end

    it 'redacts PII keys' do
      expect(request.body).not_to include('user@example.com')
    end

    it 'leaves everything else alone' do
      expect(request.body).to include('example.com')
    end
  end

  describe 'configurable key lists' do
    # A stock list cannot know an app's internal service credentials, and those
    # are usually the highest-value ones.
    it 'redacts an app-specific credential header once configured' do
      AxiomLogtail.configure { |c| c.additional_credential_keys = ['X-Acme-Key'] }

      device = described_class.new('xaat-t', 'ds')
      entry = Logtail::LogEntry.new(:info, Time.utc(2026, 8, 13), nil, 'x',
                                    { context: { 'X_Acme_Key' => 'APIKEYSECRET' } }, nil)

      expect(device.send(:build_request, [entry]).body).not_to include('APIKEYSECRET')
    end

    # Separator and case must not matter: logtail-rack presents request headers
    # as X_Acme_Key and response headers as Set-Cookie, from the same list.
    it 'matches regardless of separator or case' do
      AxiomLogtail.configure { |c| c.additional_credential_keys = ['x-custom-token'] }
      matcher = AxiomLogtail.config.redactable_key_matcher

      expect('X_Custom_Token').to match(matcher)
      expect('x-custom-token').to match(matcher)
      expect('X-CUSTOM-TOKEN').to match(matcher)
      expect('x_custom_tokens').not_to match(matcher)
    end
  end
end
