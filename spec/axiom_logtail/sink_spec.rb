# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe AxiomLogtail::Sink do
  # A REAL device, not an instance_double: `verify_in_background` type-checks
  # with `is_a?(LogDevice)` on purpose (see the impostor context below), and a
  # verifying double is not an instance of the class. Construction is cheap and
  # connects to nothing -- the parent gem starts its flush threads lazily, on
  # first #write.
  let(:device) { AxiomLogtail::LogDevice.new('xaat-test', 'app-production') }

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

  # Deferring verification is the whole point of the public method: in a Rails
  # app the sink must be built while the environment file is evaluated, which is
  # before initializers, so an error tracker is usually not up yet.
  describe '.verify_in_background' do
    it 'probes the device' do
      probed = Queue.new
      allow(device).to receive(:verify!) { probed << true }

      described_class.verify_in_background(device)

      expect(await(probed)).to be(true)
    end

    it 'reports a failure with the still-attached state' do
      allow(device).to receive(:verify!).and_raise(AxiomLogtail::LogDevice::DeliveryFailed, 'HTTP 403')
      reported = Queue.new

      described_class.verify_in_background(device, ->(error, state) { reported << [error, state] })

      error, state = await(reported)
      expect(error).to be_a(AxiomLogtail::LogDevice::DeliveryFailed)
      expect(state).to include('still attached')
    end

    # Rails' `config.x.anything_unset` auto-vivifies an OrderedOptions rather
    # than returning nil, and that object answers respond_to? TRUE for every
    # name while raising KeyError when actually called. Both consuming apps hit
    # this: their `next if device.nil?` guard never fired outside production, so
    # every dev/test/console boot spawned a thread that died with
    # `KeyError: :verify is blank` and reported the sink "still attached and
    # delivering" when none was ever built. A duck-type check does not save you
    # here -- only a type check does.
    context 'when handed something that is not a device' do
      # Stands in for ActiveSupport::OrderedOptions without depending on Rails.
      let(:impostor) do
        Class.new do
          def respond_to_missing?(_name, _include_private = false)
            true
          end

          def method_missing(name, *_args)
            raise KeyError, ":#{name} is blank"
          end
        end.new
      end

      it 'does not spawn a thread' do
        expect(Thread).not_to receive(:new)

        described_class.verify_in_background(impostor)
      end

      it 'returns nil rather than a thread' do
        expect(described_class.verify_in_background(impostor)).to be_nil
      end

      # The state must NOT claim the sink is attached and delivering.
      it 'reports that there was no sink, not a delivery failure' do
        reported = []

        described_class.verify_in_background(impostor, ->(error, state) { reported << [error, state] })

        error, state = reported.first
        expect(error).to be_a(TypeError)
        expect(state).to eq('no sink to verify')
        expect(state).not_to include('still attached')
      end

      it 'treats nil the same way' do
        expect(described_class.verify_in_background(nil)).to be_nil
      end
    end

    it 'tolerates no error handler at all' do
      allow(device).to receive(:verify!).and_raise(StandardError, 'boom')

      expect { described_class.verify_in_background(device).join(5) }.not_to raise_error
    end

    # Pairs with `build(verify: false)`: the caller defers the probe, so build
    # must not have already run one.
    it 'is the only probe when build defers verification' do
      allow(AxiomLogtail::LogDevice).to receive(:new).and_return(device)
      allow(device).to receive(:verify!)

      built = described_class.build(token: 'xaat-abc', dataset: 'app-production', verify: false)
      expect(device).not_to have_received(:verify!)

      described_class.verify_in_background(built).join(5)
      expect(device).to have_received(:verify!).once
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
