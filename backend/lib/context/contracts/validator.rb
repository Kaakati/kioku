# frozen_string_literal: true

require "time"

module Context
  module Contracts
    # Shared bound, enum and cardinality checks for the request contracts.
    #
    # Every failure is kioku.invalid_request carrying the offending field name
    # and a reason code. Values are never echoed into the message: a request
    # body can contain memory text or credentials, and error messages are
    # operator-facing and content-redacted.
    module Validator
      module_function

      def deep_stringify(value)
        case value
        when Hash then value.to_h { |key, nested| [key.to_s, deep_stringify(nested)] }
        when Array then value.map { |nested| deep_stringify(nested) }
        else value
        end
      end

      def invalid!(field, reason)
        raise Errors::InvalidRequest.new(details: { field: field, reason: reason })
      end

      def hash!(value, field:)
        invalid!(field, "expected_object") unless value.is_a?(Hash)
        value
      end

      def required(payload, key, field: key)
        hash!(payload, field: field)
        invalid!(field, "missing") unless payload.key?(key)
        payload[key]
      end

      def string!(value, field:, max:, min: 1)
        invalid!(field, "expected_string") unless value.is_a?(String)
        trimmed = value.strip
        invalid!(field, "blank") if min.positive? && trimmed.empty?
        invalid!(field, "too_short") if value.length < min
        invalid!(field, "too_long") if value.length > max
        value
      end

      # Applies a pattern taken from the frozen schema. JSON Schema's ^ and $
      # are string anchors; Ruby's are line anchors, so the pattern is re-anchored
      # with \A and \z before use.
      def pattern!(value, field:, pattern:)
        invalid!(field, "expected_string") unless value.is_a?(String)
        body = pattern.delete_prefix("^").delete_suffix("$")
        invalid!(field, "pattern_mismatch") unless Regexp.new("\\A(?:#{body})\\z").match?(value)
        value
      end

      def enum!(value, field:, allowed:)
        invalid!(field, "not_in_enum") unless allowed.include?(value)
        value
      end

      def integer!(value, field:, min:, max:)
        invalid!(field, "expected_integer") unless value.is_a?(Integer)
        invalid!(field, "below_minimum") if value < min
        invalid!(field, "above_maximum") if value > max
        value
      end

      def boolean!(value, field:)
        invalid!(field, "expected_boolean") unless value == true || value == false
        value
      end

      def array!(value, field:, max:, min: 0)
        invalid!(field, "expected_array") unless value.is_a?(Array)
        invalid!(field, "too_few_items") if value.length < min
        invalid!(field, "too_many_items") if value.length > max
        value
      end

      def string_array!(value, field:, max:, item_max: 128)
        array!(value, field: field, max: max).each_with_index do |item, index|
          string!(item, field: "#{field}[#{index}]", max: item_max)
        end
      end

      # RFC3339 in, Time out. Valid time is independent of recorded time, so a
      # caller-supplied instant is parsed but never used as the recorded time.
      def time!(value, field:)
        return nil if value.nil?

        invalid!(field, "expected_rfc3339_string") unless value.is_a?(String)
        Time.iso8601(value)
      rescue ArgumentError
        invalid!(field, "malformed_rfc3339")
      end

      # Authority, actor identity and the other core-derived labels are derived
      # from the authenticated transport. A request that supplies one is
      # rejected rather than ignored, so a caller can never believe it set them.
      def reject_core_derived!(payload, field: "request")
        hash!(payload, field: field)
        supplied = Vocabulary.core_derived_fields & payload.keys
        return payload if supplied.empty?

        raise Errors::InvalidRequest.new(details: { field: field, reason: "core_derived_field_supplied", fields: supplied })
      end

      def reject_unknown!(payload, allowed:, field: "request")
        unknown = payload.keys - allowed
        return payload if unknown.empty?

        raise Errors::InvalidRequest.new(details: { field: field, reason: "unknown_fields", fields: unknown })
      end
    end
  end
end
