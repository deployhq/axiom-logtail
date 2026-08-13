# frozen_string_literal: true

module AxiomLogtail
  # Configures `logtail-rack`'s header redaction.
  #
  # WHY THIS EXISTS. `logtail-rack` logs every request and response header on its
  # `http_request_received` / `http_response_sent` events. It ships
  # `http_header_filters` for exactly this, but it defaults to `nil` and the
  # check is `http_header_filters&.include?`, so an UNCONFIGURED app logs every
  # header verbatim -- including Cookie and Authorization. Configuring it wrong
  # is equally silent: a name that does not match filters nothing, and there is
  # no warning.
  #
  # HOW MATCHING ACTUALLY WORKS. Get this right before editing a list.
  #
  #   * Request headers do NOT reach the filter as rack env keys.
  #     `HTTPEvents#call` wraps the env in `Logtail::Util::Request`, whose
  #     `#headers` strips the `HTTP_` prefix, splits on `_` and capitalises each
  #     part. `HTTP_X_CSRF_TOKEN` therefore arrives as `X_Csrf_Token`.
  #   * Response headers arrive unprefixed already (`Set-Cookie`, `Location`).
  #   * `normalize_header_name` then downcases and turns `-` into `_`, on BOTH
  #     the incoming name and every configured entry (the setter maps the whole
  #     list through it).
  #
  # The upshot: the canonical hyphenated spelling matches both request and
  # response forms, and casing is irrelevant. `HTTP_`-prefixed entries match
  # nothing the middleware currently produces -- `include_rack_forms:` adds them
  # only as insurance against a future change in `Util::Request#headers`.
  module HeaderFilters
    # Credential-bearing headers any Rails app may receive. Apps add their own
    # via `extra:` -- a stock list will not know about your internal service
    # keys, and those are usually the highest-value ones.
    DEFAULT = %w[
      Authorization
      Proxy-Authorization
      Cookie
      Set-Cookie
      X-CSRF-Token
      X-Api-Key
      X-Auth-Token
      X-Amz-Security-Token
    ].freeze

    class << self
      # @param extra [Array<String>] app-specific credential headers
      # @param only [Array<String>, nil] replace the defaults entirely
      # @param include_rack_forms [Boolean] also emit HTTP_-prefixed variants
      # @return [Array<String>] the list as configured, for assertion in specs
      def apply!(extra: [], only: nil, include_rack_forms: true)
        names = (only || DEFAULT + extra).uniq
        filters = include_rack_forms ? names.flat_map { |n| [n, rack_form(n)] } : names.dup

        Logtail::Integrations::Rack::HTTPEvents.http_header_filters = filters
        names
      end

      # "X-CSRF-Token" -> "HTTP_X_CSRF_TOKEN"
      def rack_form(name)
        "HTTP_#{name.upcase.tr('-', '_')}"
      end

      # The name the middleware actually presents for a request header:
      # "X-CSRF-Token" -> "X_Csrf_Token". Use this in specs so they assert the
      # shape production emits rather than one it never does.
      def middleware_form(name)
        name.tr('-', '_').split('_').map(&:capitalize).join('_')
      end
    end
  end
end
