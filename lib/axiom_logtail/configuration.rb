# frozen_string_literal: true

module AxiomLogtail
  # Host applications differ in which keys are credentials -- one app's
  # `X-Acme-Key` is another's `X-Service-PSK` -- so the lists are configuration
  # rather than constants. Defaults cover the keys any Rails app is likely to
  # emit; `additional_*` extends without having to restate them.
  class Configuration
    # Deliberately broader than what any one application actually emits. The cost
    # of an extra alternation is nothing; the cost of a miss is a credential at a
    # third party.
    DEFAULT_CREDENTIAL_KEYS = %w[
      cookie set-cookie
      authorization proxy-authorization
      x-csrf-token x-api-key x-auth-token x-amz-security-token
      api-key access-token refresh-token session-token
      secret password passwd token
    ].freeze

    # Direct customer identifiers. Structured keys only -- an address embedded in
    # a free-text message still passes through, and scrubbing message bodies
    # belongs upstream of a log device, where it can be done once rather than on
    # every event.
    DEFAULT_PII_KEYS = %w[email e-mail email-address].freeze

    # Matches the underlying gem's own defaults. Worth stating explicitly: the
    # request queue DROPS when full rather than blocking, so under-sizing it
    # loses log lines silently. #write runs on the request path, so blocking
    # instead would turn a slow sink into an application outage -- dropping is
    # the correct failure mode, which is why the bound needs to be generous.
    DEFAULT_BATCH_SIZE = 1_000
    DEFAULT_REQUEST_QUEUE_SIZE = 25

    # Above this, parsing an embedded JSON string costs more than it is worth.
    # Oversized blobs get the textual scrub instead -- never passed through
    # unexamined.
    DEFAULT_MAX_EMBEDDED_JSON_BYTES = 64_000

    attr_accessor :credential_keys, :pii_keys,
                  :additional_credential_keys, :additional_pii_keys,
                  :batch_size, :request_queue_size,
                  :max_embedded_json_bytes, :user_agent

    def initialize
      @credential_keys = DEFAULT_CREDENTIAL_KEYS.dup
      @pii_keys = DEFAULT_PII_KEYS.dup
      @additional_credential_keys = []
      @additional_pii_keys = []
      @batch_size = DEFAULT_BATCH_SIZE
      @request_queue_size = DEFAULT_REQUEST_QUEUE_SIZE
      @max_embedded_json_bytes = DEFAULT_MAX_EMBEDDED_JSON_BYTES
      @user_agent = "axiom-logtail/#{AxiomLogtail::VERSION}"
    end

    # Matches a key regardless of separator or case, so a list entry of
    # `x-api-key` also catches `X_Api_Key` and `X-API-KEY`. That matters more than
    # it looks: `logtail-rack` presents request headers as `X_Api_Key` (it strips
    # the rack `HTTP_` prefix and capitalises each underscore-separated part),
    # while response headers arrive as `Set-Cookie`. A matcher keyed on one
    # spelling silently misses the other.
    def redactable_key_matcher
      @redactable_key_matcher ||= build_matcher(all_keys)
    end

    def all_keys
      credential_keys + additional_credential_keys + pii_keys + additional_pii_keys
    end

    # Call after mutating any key list; the matcher is memoised.
    def reset_matcher!
      @redactable_key_matcher = nil
    end

    private

    def build_matcher(keys)
      alternatives = keys.map do |key|
        key.to_s.downcase.split(/[-_]/).map { |part| Regexp.escape(part) }.join('[-_]')
      end

      /\A(?:#{alternatives.uniq.join('|')})\z/i
    end
  end
end
