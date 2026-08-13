# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'

module AxiomLogtail
  # Ships log events to Axiom.
  #
  # Subclasses the Logtail HTTP device and overrides ONLY the wire format.
  # Everything expensive and easy to get wrong -- batching, the flush thread, the
  # keep-alive request outlet, retry/backoff, backpressure, UTF-8 coercion -- is
  # inherited unchanged. Axiom's own Rails guide has you hand-roll this with
  # Faraday, which puts a synchronous HTTP client in the logging path.
  #
  # Three details are load-bearing and were each established by testing against
  # real Axiom rather than from its documentation:
  #
  #   1. The ingest path is `/v1/ingest/<dataset>`. The documented-looking
  #      `/v1/datasets/<dataset>/ingest` returns 404.
  #   2. Ingest MUST go to the dataset's regional edge host, not api.axiom.co,
  #      which rejects it with 400. Sending to the wrong region also silently
  #      defeats data residency.
  #   3. `?timestamp-field=dt` is REQUIRED. Without it Axiom ignores the event's
  #      own timestamp and stamps everything at ingest time -- while returning
  #      200 and "ingested":1, so the failure is invisible.
  class LogDevice < Logtail::LogDevices::HTTP
    # Must match the dataset's "Edge deployment" setting.
    EDGE_HOSTS = {
      'eu-central-1' => 'eu-central-1.aws.edge.axiom.co',
      'us-east-1' => 'us-east-1.aws.edge.axiom.co'
    }.freeze

    DEFAULT_REGION = 'eu-central-1'

    # Anything outside this would be interpolated raw into the request path, and
    # a stray "?" or "/" would drop the load-bearing timestamp-field parameter
    # while still returning 200.
    VALID_DATASET = /\A[A-Za-z0-9._-]+\z/.freeze

    REDACTED = '[REDACTED]'

    class UnknownRegion < StandardError; end
    class InvalidDataset < StandardError; end
    class DeliveryFailed < StandardError; end

    def self.edge_host_for(region)
      EDGE_HOSTS.fetch(region) do
        raise UnknownRegion, "Unknown Axiom region #{region.inspect}. Known: #{EDGE_HOSTS.keys.join(', ')}"
      end
    end

    # @param api_token [String] an Axiom API token (xaat-...), NOT a Personal
    #   Access Token -- a PAT additionally requires an x-axiom-org-id header.
    # @param dataset [String] target dataset name; Axiom does not create it on
    #   ingest, so a missing dataset 404s every batch.
    # @param region [String] must match the dataset's edge deployment.
    def initialize(api_token, dataset, region: DEFAULT_REGION, **options)
      raise InvalidDataset, "Invalid Axiom dataset name #{dataset.inspect}" unless dataset.to_s.match?(VALID_DATASET)

      @dataset = dataset
      @region = region
      @config = AxiomLogtail.config

      super(api_token, {
        batch_size: @config.batch_size,
        request_queue: Logtail::LogDevices::HTTP::FlushableDroppingSizedQueue.new(@config.request_queue_size)
      }.merge(options).merge(
        logtail_host: self.class.edge_host_for(region),
        logtail_port: 443,
        logtail_scheme: 'https'
      ))
    end

    # Status code of the most recent async delivery, or nil if none has completed.
    #
    # The parent retries only on transport EXCEPTIONS -- a non-2xx response is
    # stored and otherwise ignored, so a wrong path, revoked token or bad region
    # drops every batch while the application looks perfectly healthy.
    def last_response_code
      resp = instance_variable_get(:@last_resp)
      resp.respond_to?(:code) ? resp.code.to_i : nil
    end

    # Synchronously deliver one probe event and confirm Axiom accepted it. Use at
    # boot so misconfiguration fails loudly instead of silently discarding logs.
    def verify!
      probe = Logtail::LogEntry.new(:info, Time.now.utc, nil, 'axiom-logtail verification probe', {}, nil)
      result = deliver_one(probe)

      raise DeliveryFailed, "Axiom probe failed: #{result.class}: #{result.message}" if result.is_a?(Exception)

      code = result.code.to_i
      unless (200..299).cover?(code)
        raise DeliveryFailed,
              "Axiom rejected probe with HTTP #{code} (dataset=#{@dataset} region=#{@region})"
      end

      code
    end

    # The parent short-circuits #write on a global vendor-specific filter.
    # Inheriting it would mean any filter configured for another sink silently
    # suppresses this one by the same amount.
    def write(msg)
      @msg_queue.enq(msg)
      ensure_flush_threads_are_started
      flush_async if @msg_queue.full?
      true
    end

    private

    # The parent disables TLS peer verification (for a historical Windows issue).
    # Inheriting that would send log contents and a long-lived ingest token over
    # unverified TLS. Restored here rather than by patching the parent gem.
    def build_http
      http = super
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http
    end

    def build_request(msgs)
      req = Net::HTTP::Post.new("/v1/ingest/#{@dataset}?timestamp-field=dt")
      req['Authorization'] = authorization_payload
      req['Content-Type'] = 'application/json'
      req['User-Agent'] = @config.user_agent
      req.body = msgs.map { |msg| redact(force_utf8_encoding(msg.to_hash)) }.to_json
      req
    end

    # Walks the whole event rather than digging a fixed path, so a credential
    # under an unanticipated key is still caught -- INCLUDING inside values that
    # are themselves serialised JSON.
    def redact(value, key = nil)
      case value
      when Hash
        value.each_with_object({}) do |(nested_key, nested), acc|
          acc[nested_key] = redactable_key?(nested_key) ? REDACTED : redact(nested, nested_key)
        end
      when Array
        value.map { |nested| redact(nested, key) }
      when String
        redact_embedded_json(value)
      else
        value
      end
    end

    def redactable_key?(key)
      key.to_s.match?(@config.redactable_key_matcher)
    end

    # Parse -> redact -> reserialise, so credentials inside a JSON string are
    # caught. Falls back to a textual scrub rather than emitting a blob that was
    # never examined.
    #
    # Deliberately NOT limited to keys whose names suggest embedded JSON. An
    # earlier version keyed off a `_json` suffix and shipped live Basic-auth
    # credentials, because the app's actual field naming did not match the
    # assumption. Any JSON-shaped string is examined.
    def redact_embedded_json(string)
      return string unless string.start_with?('{', '[')
      return scrub_text(string) if string.bytesize > @config.max_embedded_json_bytes

      redact(JSON.parse(string)).to_json
    rescue JSON::ParserError, EncodingError
      scrub_text(string)
    end

    # Last line of defence for JSON that will not parse or is too large to.
    # Rewrites "SensitiveKey":"value" in place, leaving structure untouched.
    def scrub_text(string)
      string.gsub(/"([^"]+)"\s*:\s*"(?:[^"\\]|\\.)*"/) do
        key = Regexp.last_match(1)
        redactable_key?(key) ? %("#{key}":"#{REDACTED}") : Regexp.last_match(0)
      end
    end
  end
end
