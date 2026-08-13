# frozen_string_literal: true

require 'digest'
require 'json'

module AxiomLogtail
  # Bounds the params carried by `logtail`'s `controller_called` event.
  #
  # `Logtail::Events::ControllerCall` serialises request params TWICE per request:
  #
  #   @params_json = @params.to_json                  # structured field
  #   message << "\n  Parameters: #{params.inspect}"  # human-readable message
  #
  # Neither copy is size-capped, so any controller accepting a third-party
  # payload emits a log event proportional to the inbound body -- and pays for it
  # twice. A single webhook endpoint receiving large payloads can dominate an
  # entire log bill.
  #
  # The bound is applied to the params BEFORE the event serialises anything, so
  # both representations shrink from one pass and the oversized `inspect` string
  # is never built. It is applied globally rather than per-controller because the
  # defect is in the event class, not in any one endpoint.
  #
  # Design notes, each driven by a real failure:
  #
  #   * Pruning is RECURSIVE. Bounding only top-level values collapses an ordinary
  #     nested form post to a single marker, losing which resource was touched.
  #   * The initial size probe serialises the WHOLE structure once, not per key.
  #     Summing per-value sizes ignores key bytes, so a payload with a huge key
  #     name and tiny values sails past the cap untouched.
  #   * An unserialisable value forces the prune path. Scoring it as a fixed size
  #     lets the total fit, params return unchanged, and the gem's own `to_json`
  #     raises -- dropping the event and writing a backtrace to the same paid sink.
  #   * The over-budget fallback drops the LARGEST entries first rather than
  #     discarding everything, so identifiers survive a payload of medium fields.
  module BoundedParams
    # Total serialised bytes before pruning starts.
    BYTE_LIMIT = 2048

    # A leaf over this is replaced individually, so small high-value keys survive
    # alongside a dropped bulk array.
    VALUE_BYTE_LIMIT = 512

    # How far to descend before replacing a subtree wholesale. Bounds the work on
    # hostile input.
    MAX_DEPTH = 4

    # Without this, thousands of individually-small items each pass the leaf check
    # and the array stays huge.
    MAX_ARRAY_ITEMS = 10

    # Keys are untrusted input too. Detecting an oversized payload is not enough
    # if the bytes live in the key name.
    MAX_KEY_BYTES = 128

    TRUNCATED_KEY = '_params_truncated_bytes'
    FAILED_KEY = '_params_bounding_failed'
    DROPPED_KEY = '_params_dropped_keys'

    # Room held back for the meta fields appended after the budget is spent.
    RESERVED_META_BYTES = 96

    # Distinct from a size marker on purpose: reporting a fabricated byte count
    # for an unencodable value is telemetry that lies.
    UNSERIALIZABLE = '[unserializable]'

    class << self
      # Prepend the patch to the event class. Idempotent.
      def install!
        return false if Logtail::Events::ControllerCall.ancestors.include?(EventPatch)

        Logtail::Events::ControllerCall.prepend(EventPatch)
        true
      end

      # Never raises: a bug in here must not cost a log line, and must never
      # surface as a request-visible error.
      def safe_bound(params)
        bound(params)
      rescue StandardError, SystemStackError
        { FAILED_KEY => true }
      end

      def bound(params)
        return params if empty?(params)

        total = json_bytesize(params)
        # A nil total means something will not serialise -- prune regardless of size.
        return params if total && total <= BYTE_LIMIT

        pruned = shrink(params, 0)
        return pruned unless pruned.is_a?(Hash)

        pruned = squeeze(pruned)
        pruned[TRUNCATED_KEY] = total if total

        # Everything above is budgeted arithmetic. This asserts the arithmetic
        # actually held, because "the result fits" is the entire contract -- and
        # the one bug that mattered here was a bound that silently GREW the
        # payload instead.
        return { TRUNCATED_KEY => total, DROPPED_KEY => pruned.size }.compact if oversized?(pruned)

        pruned
      end

      private

      # Deliberately not ActiveSupport's #blank? -- this gem should not require
      # Rails to be loaded.
      def empty?(params)
        params.nil? || (params.respond_to?(:empty?) && params.empty?)
      end

      # Replaces oversized or unserialisable leaves while keeping the surrounding
      # shape, so the log still shows which resource the request touched.
      def shrink(value, depth)
        size = json_bytesize(value)
        return value if size && size <= VALUE_BYTE_LIMIT
        return marker(value, size) if depth >= MAX_DEPTH

        case value
        when Hash
          value.each_with_object({}) { |(key, nested), out| out[bound_key(key)] = shrink(nested, depth + 1) }
        when Array
          shrink_array(value, depth)
        else
          marker(value, size)
        end
      end

      def shrink_array(value, depth)
        kept = value.first(MAX_ARRAY_ITEMS).map { |nested| shrink(nested, depth + 1) }
        dropped = value.size - MAX_ARRAY_ITEMS
        kept << "[+#{dropped} more items]" if dropped.positive?
        kept
      end

      # Backstop after recursive shrinking, which preserves structure but cannot
      # guarantee a total: many small values each pass the leaf check.
      #
      # Fills a byte budget smallest-entry-first. Two things that look reasonable
      # and are not:
      #
      #   * Replacing an entry with a marker. For a small value the marker is
      #     BIGGER than what it replaces -- 300 tiny pairs grew from 3,191 to
      #     11,022 bytes, so the function meant to bound the payload made it 3.5x
      #     worse than doing nothing. By this point `shrink` has already markered
      #     every oversized leaf, so anything still here is small.
      #   * Summing key and value bytes as the total. That omits braces, commas
      #     and colons, so four 504-byte values measured 2,040 and serialised to
      #     2,049.
      #
      # Smallest-first because small keys are the high-value ones -- identifiers
      # survive and the bulk is what gets dropped.
      def squeeze(hash)
        budget = BYTE_LIMIT - RESERVED_META_BYTES
        entries = hash.map { |key, value| [key, value, entry_bytes(key, value)] }
        entries.sort_by! { |entry| entry[2] }

        kept = {}
        used = 2 # the enclosing {}
        dropped = 0

        entries.each do |key, value, size|
          if used + size + 1 <= budget # +1 for the separating comma
            kept[key] = value
            used += size + 1
          else
            dropped += 1
          end
        end

        kept[DROPPED_KEY] = dropped if dropped.positive?
        kept
      end

      def oversized?(value)
        size = json_bytesize(value)
        size.nil? || size > BYTE_LIMIT
      end

      # Bytes this pair contributes to the serialised object: "key":value
      def entry_bytes(key, value)
        (json_bytesize(key.to_s) || 0) + 1 + (json_bytesize(value) || UNSERIALIZABLE.to_json.bytesize)
      end

      # Type and cardinality cost ~15 bytes and answer the first question a
      # reader asks: was that 40 items or 4,000?
      def marker(value, size)
        return UNSERIALIZABLE if size.nil?

        shape = case value
                when Hash then "Hash(#{value.size} keys)"
                when Array then "Array(#{value.size} items)"
                else value.class.to_s
                end

        "[truncated #{shape}: #{size} bytes]"
      end

      # byteslice can land mid-codepoint; scrub so the result is always valid
      # UTF-8 and the JSON encoder cannot choke on it.
      def bound_key(key)
        string = key.to_s
        return key if string.bytesize <= MAX_KEY_BYTES

        # A prefix plus a length is not unique: two oversized keys sharing both
        # would bound to the SAME key, and the later assignment would silently
        # drop the earlier value. The digest makes them distinct. The prefix is
        # budgeted against the suffix so the result stays inside MAX_KEY_BYTES.
        suffix = "[truncated key: #{string.bytesize}B #{Digest::SHA256.hexdigest(string)[0, 8]}]"
        prefix = string.byteslice(0, [MAX_KEY_BYTES - suffix.bytesize, 0].max).to_s.scrub('')
        "#{prefix}#{suffix}"
      end

      # nil signals "cannot be serialised" rather than a fabricated size.
      def json_bytesize(value)
        value.to_json.bytesize
      rescue StandardError, SystemStackError
        nil
      end
    end

    # Prepended to the event class so the gem keeps ownership of the event's
    # shape; we only bound what goes into it.
    module EventPatch
      def initialize(attributes)
        bounded = attributes.dup
        bounded[:params] = BoundedParams.safe_bound(attributes[:params])
        super(bounded)
      end
    end
  end
end
