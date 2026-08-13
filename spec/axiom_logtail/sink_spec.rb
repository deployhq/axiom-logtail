# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe AxiomLogtail::Sink do
  let(:device) { instance_double(AxiomLogtail::LogDevice) }

  before do
    # stderr belongs to the suite, not to these examples.
    allow(described_class).to receive(:warn)
  end

  # Waits on the background verification thread without sleeping. A bare `pop`
  # would hang the suite if the report never arrives, which is itself the
  # failure worth catching.
  def await(queue, seconds = 5)
    Timeout.timeout(seconds) { queue.pop }
  end

  describe '.build' do
    context 'when configured' do
      before { allow(AxiomLogtail::LogDevice).to receive(:new).and_return(device) }

      it 'returns a device' do
        allow(device).to receive(:verify!)

        expect(described_class.build(token: 'xaat-abc', dataset: 'app-production')).to be(device)
      end

      it 'defaults to the gem default region rather than passing nil through' do
        allow(device).to receive(:verify!)

        described_class.build(token: 'xaat-abc', dataset: 'app-production', region: nil)

        expect(AxiomLogtail::LogDevice)
          .to have_received(:new)
          .with('xaat-abc', 'app-production', region: AxiomLogtail::LogDevice::DEFAULT_REGION)
      end

      it 'treats a blank region as absent' do
        allow(device).to receive(:verify!)

        described_class.build(token: 'xaat-abc', dataset: 'app-production', region: '  ')

        expect(AxiomLogtail::LogDevice)
          .to have_received(:new)
          .with('xaat-abc', 'app-production', region: AxiomLogtail::LogDevice::DEFAULT_REGION)
      end

      it 'passes an explicit region through' do
        allow(device).to receive(:verify!)

        described_class.build(token: 'xaat-abc', dataset: 'app-production', region: 'us-east-1')

        expect(AxiomLogtail::LogDevice)
          .to have_received(:new)
          .with('xaat-abc', 'app-production', region: 'us-east-1')
      end
    end

    context 'when switched off or unconfigured' do
      before { allow(AxiomLogtail::LogDevice).to receive(:new).and_return(device) }

      # Asserting the device was never CONSTRUCTED, not merely that nil came
      # back: the kill switch has to prevent the background probe and its
      # thread too, not just withhold the return value.
      it 'is inert when disabled, even with valid credentials' do
        expect(described_class.build(token: 'xaat-abc', dataset: 'app-production', disabled: true)).to be_nil
        expect(AxiomLogtail::LogDevice).not_to have_received(:new)
      end

      it 'is inert without a token' do
        expect(described_class.build(token: nil, dataset: 'app-production')).to be_nil
        expect(AxiomLogtail::LogDevice).not_to have_received(:new)
      end

      it 'is inert without a dataset' do
        expect(described_class.build(token: 'xaat-abc', dataset: nil)).to be_nil
        expect(AxiomLogtail::LogDevice).not_to have_received(:new)
      end

      # The case that actually bites: a secret that is present but empty reads
      # as configured to a naive nil check.
      it 'treats an empty-string credential as unconfigured' do
        expect(described_class.build(token: '', dataset: 'app-production')).to be_nil
        expect(described_class.build(token: 'xaat-abc', dataset: '   ')).to be_nil
        expect(AxiomLogtail::LogDevice).not_to have_received(:new)
      end
    end

    context 'when the device cannot be built' do
      # A real rejection from LogDevice, not a stubbed raise -- an invalid
      # dataset name is the misconfiguration most likely to reach production,
      # and it must not take boot down.
      it 'returns nil instead of raising' do
        expect(described_class.build(token: 'xaat-abc', dataset: 'bad name/with slash', verify: false)).to be_nil
      end

      it 'reports that the sink is disabled' do
        reported = []

        described_class.build(
          token: 'xaat-abc',
          dataset: 'bad name/with slash',
          verify: false,
          on_error: ->(error, state) { reported << [error, state] }
        )

        error, state = reported.first
        expect(error).to be_a(AxiomLogtail::LogDevice::InvalidDataset)
        expect(state).to eq('sink disabled')
      end

      it 'survives an on_error handler that itself raises' do
        expect do
          described_class.build(
            token: 'xaat-abc',
            dataset: 'bad name/with slash',
            verify: false,
            on_error: ->(_error, _state) { raise 'reporting is broken' }
          )
        end.not_to raise_error
      end
    end

    describe 'delivery verification' do
      before { allow(AxiomLogtail::LogDevice).to receive(:new).and_return(device) }

      it 'probes delivery by default' do
        probed = Queue.new
        allow(device).to receive(:verify!) { probed << true }

        described_class.build(token: 'xaat-abc', dataset: 'app-production')

        expect(await(probed)).to be(true)
      end

      it 'skips the probe when asked' do
        allow(device).to receive(:verify!)

        described_class.build(token: 'xaat-abc', dataset: 'app-production', verify: false)

        expect(device).not_to have_received(:verify!)
      end

      # The distinction that matters operationally. A failed probe means the
      # sink is misconfigured, NOT that it was detached -- an operator told
      # "disabled" would go looking for a sink that is in fact live and
      # shipping.
      it 'keeps the device attached when the probe fails, and says so' do
        allow(device).to receive(:verify!).and_raise(
          AxiomLogtail::LogDevice::DeliveryFailed, 'Axiom rejected probe with HTTP 401'
        )
        reported = Queue.new

        result = described_class.build(
          token: 'xaat-abc',
          dataset: 'app-production',
          on_error: ->(error, state) { reported << [error, state] }
        )

        expect(result).to be(device)

        error, state = await(reported)
        expect(error).to be_a(AxiomLogtail::LogDevice::DeliveryFailed)
        expect(state).to include('still attached')
        expect(state).not_to include('disabled')
      end

      it 'does not raise out of the background thread on a failed probe' do
        allow(device).to receive(:verify!).and_raise(StandardError, 'boom')

        thread = nil
        allow(Thread).to receive(:new) { |&block| thread = Thread.start(&block) }

        described_class.build(token: 'xaat-abc', dataset: 'app-production')

        expect { thread.join(5) }.not_to raise_error
      end
    end
  end

  describe '.scrub' do
    it 'redacts an ingest token' do
      message = 'failed to POST https://eu-central-1.aws.edge.axiom.co: token xaat-s3cr3t-Value.1 rejected'

      expect(described_class.scrub(message)).to eq(
        'failed to POST https://eu-central-1.aws.edge.axiom.co: token [REDACTED_AXIOM_TOKEN] rejected'
      )
    end

    # A personal access token in this position is a misconfiguration, and the
    # error it produces is exactly where it would otherwise be echoed.
    it 'redacts a personal access token too' do
      expect(described_class.scrub('bad credential xapt-abc123')).to eq('bad credential [REDACTED_AXIOM_TOKEN]')
    end

    it 'redacts every occurrence' do
      expect(described_class.scrub('xaat-one and xaat-two')).to eq(
        '[REDACTED_AXIOM_TOKEN] and [REDACTED_AXIOM_TOKEN]'
      )
    end

    it 'leaves messages without a token untouched' do
      expect(described_class.scrub('connection reset by peer')).to eq('connection reset by peer')
    end

    it 'handles a nil message' do
      expect(described_class.scrub(nil)).to eq('')
    end
  end
end
