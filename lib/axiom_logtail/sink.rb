# frozen_string_literal: true

module AxiomLogtail
  # Builds a configured `LogDevice`, or returns nil so the caller keeps whatever
  # logger it already had.
  #
  # Constructing the device is one line; everything that makes it SAFE to
  # construct during boot is not, and every host application needs the same
  # four things:
  #
  #   1. A kill switch that does not require a deploy.
  #   2. Inertness when unconfigured, so merging the wiring changes nothing
  #      until an environment is deliberately opted in.
  #   3. Delivery verification, because the parent gem ignores non-2xx entirely
  #      -- a bad token, missing dataset or wrong region discards every batch
  #      while the application looks perfectly healthy.
  #   4. Never raising. A logging sink that breaks boot is worse than one that
  #      is absent.
  #
  # Reimplementing that per application is how the four quietly drift apart, so
  # it lives here. This module deliberately takes plain values rather than
  # reading configuration itself -- host apps disagree about where secrets live
  # (`Rails.application.secrets`, ENV, Konfig), and that disagreement is the
  # caller's business, not this gem's.
  module Sink
    REDACTED_TOKEN = '[REDACTED_AXIOM_TOKEN]'

    # Axiom API tokens are `xaat-`; personal access tokens are `xapt-`. Match
    # both -- a PAT in this position is a misconfiguration, and the resulting
    # error message is exactly where it would otherwise leak.
    TOKEN_PATTERN = /xa(?:at|pt)-[A-Za-z0-9._-]+/.freeze

    class << self
      # @param token [String, nil] Axiom API token (`xaat-...`)
      # @param dataset [String, nil] target dataset; Axiom does NOT create it on
      #   ingest, so a name that does not already exist 404s every batch
      # @param region [String, nil] defaults to `LogDevice::DEFAULT_REGION`
      # @param disabled [Boolean] kill switch. Wire this to an env var rather
      #   than to the credentials: unsetting a secret is a deploy, an env var is
      #   a restart, and rolling a vendor back mid-incident should not need the
      #   slower one.
      # @param verify [Boolean] probe delivery in a background thread
      # @param on_error [#call, nil] called as `(error, state)` for reporting.
      #   `state` describes what actually happened, and the two cases differ:
      #   a build failure really does disable the sink, a verification failure
      #   does NOT -- the device is already attached and still shipping.
      # @return [LogDevice, nil] nil whenever Axiom is off, unconfigured, or
      #   could not be built
      def build(token:, dataset:, region: nil, disabled: false, verify: true, on_error: nil)
        return nil if disabled
        return nil if blank?(token) || blank?(dataset)

        device = LogDevice.new(token, dataset, region: region_for(region))
        verify_in_background(device, on_error) if verify
        device
      rescue StandardError => e
        notify(on_error, e, 'sink disabled')
        nil
      end

      # Net::HTTP and URI errors echo request lines and URIs, and an Axiom ingest
      # token is long-lived. Never let one reach a log or an error tracker
      # verbatim.
      def scrub(message)
        message.to_s.gsub(TOKEN_PATTERN, REDACTED_TOKEN)
      end

      private

      def region_for(region)
        blank?(region) ? LogDevice::DEFAULT_REGION : region
      end

      # Off-thread so boot never blocks on an external HTTP call. The device is
      # returned and attached either way -- this surfaces a misconfiguration, it
      # does not remediate one.
      def verify_in_background(device, on_error)
        Thread.new do
          device.verify!
        rescue StandardError => e
          notify(on_error, e, 'verification FAILED, sink still attached and delivering')
        end
      end

      # `warn` always reaches stderr, which process supervisors capture. That
      # matters because this often runs before the host application's error
      # tracker is initialised, when a capture call alone is a silent no-op.
      def notify(on_error, error, state)
        warn "[AxiomLogtail::Sink] #{state}: #{error.class}: #{scrub(error.message)}"
        on_error.call(error, state) if on_error.respond_to?(:call)
      rescue StandardError
        # A failing error handler must not become the thing that breaks logging.
        nil
      end

      # Deliberately not ActiveSupport's #blank? -- this gem should not require
      # Rails. Covers the case that actually bites: a secret present but empty.
      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
