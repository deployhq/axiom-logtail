# frozen_string_literal: true

require 'logtail-rack'

# These assert the RUNTIME EFFECT of the configured filter against the header
# shapes the middleware ACTUALLY produces -- not the contents of a list, and not
# raw rack env keys.
#
# Both distinctions are load-bearing, and both have caused real leaks:
#
#   * The gem's filter fails silently when a name does not match, so a spec that
#     checks the configured array proves nothing.
#   * `logtail-rack` does NOT pass rack env keys to the filter. It wraps the env
#     in `Logtail::Util::Request`, whose `#headers` strips `HTTP_` and
#     capitalises each part. A suite built on `HTTP_COOKIE` fixtures goes green
#     while testing a path production never executes.
RSpec.describe AxiomLogtail::HeaderFilters do
  let(:events) { Logtail::Integrations::Rack::HTTPEvents }
  let(:middleware) { events.allocate }

  def filter(headers)
    middleware.send(:filter_http_headers, headers)
  end

  # The real producer.
  def request_headers(env_overrides)
    Logtail::Util::Request.new(Rack::MockRequest.env_for('/x', env_overrides)).headers
  end

  # Restored via the ivar, not the setter: `http_header_filters=` maps over its
  # argument, so it raises on nil and cannot un-configure. Worth knowing -- an
  # app cannot "clear" the filter once set, only replace it.
  around do |example|
    original = events.http_header_filters
    example.run
    events.instance_variable_set(:@http_header_filters, original)
  end

  # Pins the assumption everything else rests on. If a gem upgrade changes
  # de-prefixing, this fails first and explains why.
  describe '.middleware_form' do
    it 'matches what Logtail::Util::Request actually produces' do
      expect(request_headers('HTTP_X_CSRF_TOKEN' => 'x', 'HTTP_COOKIE' => 'y').keys)
        .to contain_exactly('X_Csrf_Token', 'Cookie')
    end

    it 'predicts that shape from a canonical name' do
      expect(described_class.middleware_form('X-CSRF-Token')).to eq('X_Csrf_Token')
      expect(described_class.middleware_form('Cookie')).to eq('Cookie')
    end
  end

  describe '.apply!' do
    it 'redacts the defaults in the form the middleware presents them' do
      described_class.apply!

      filtered = filter(request_headers('HTTP_COOKIE' => '_session=SECRET',
                                        'HTTP_AUTHORIZATION' => 'Bearer SECRET',
                                        'HTTP_USER_AGENT' => 'Mozilla/5.0'))

      expect(filtered['Cookie']).to eq('[FILTERED]')
      expect(filtered['Authorization']).to eq('[FILTERED]')
      expect(filtered['User_Agent']).to eq('Mozilla/5.0')
    end

    it 'redacts response headers, which arrive unprefixed' do
      described_class.apply!

      expect(filter('Set-Cookie' => '_session=SECRET; HttpOnly')['Set-Cookie']).to eq('[FILTERED]')
    end

    # Casing is irrelevant because normalize_header_name downcases both sides.
    # Rack 3 lowercases response header names, so this is forward cover.
    it 'redacts regardless of casing' do
      described_class.apply!

      %w[set-cookie SET-COOKIE].each do |name|
        expect(filter(name => 'SECRET')[name]).to eq('[FILTERED]')
      end
    end

    # A stock list cannot know an app's internal service credentials, and those
    # are usually the highest-value ones.
    it 'redacts app-specific headers passed via extra:' do
      described_class.apply!(extra: %w[X-Acme-Key])

      expect(filter('X_Acme_Key' => 'APIKEYSECRET')['X_Acme_Key']).to eq('[FILTERED]')
    end

    it 'replaces the defaults entirely when only: is given' do
      names = described_class.apply!(only: %w[Cookie])

      expect(names).to eq(%w[Cookie])
      expect(filter('Authorization' => 'Bearer SECRET')['Authorization']).to eq('Bearer SECRET')
    end

    it 'returns the canonical names, for assertion by the host app' do
      expect(described_class.apply!(extra: %w[X-Custom])).to include('Cookie', 'X-Custom')
    end

    # The rack forms match nothing the middleware currently produces. They are
    # insurance against a future change in Util::Request#headers, not the
    # mechanism -- an earlier version of this code had that backwards.
    it 'emits rack-form variants only as belt-and-braces' do
      described_class.apply!(only: %w[Cookie], include_rack_forms: true)

      expect(events.http_header_filters).to include('cookie', 'http_cookie')
    end

    it 'can omit the rack forms entirely without changing what is redacted' do
      described_class.apply!(only: %w[Cookie], include_rack_forms: false)

      expect(events.http_header_filters).to eq(['cookie'])
      expect(filter(request_headers('HTTP_COOKIE' => 'SECRET'))['Cookie']).to eq('[FILTERED]')
    end
  end

  # Over-filtering destroys debugging value, so it should fail too.
  it 'does not filter headers absent from the list' do
    described_class.apply!

    filtered = filter(request_headers('HTTP_X_REQUEST_ID' => 'abc123', 'HTTP_REFERER' => 'https://example.com'))

    expect(filtered['X_Request_Id']).to eq('abc123')
    expect(filtered['Referer']).to eq('https://example.com')
  end
end
