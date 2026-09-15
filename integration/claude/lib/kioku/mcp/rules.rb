# frozen_string_literal: true

require_relative "../errors"

module Kioku
  module Mcp
    # Validation primitives shared by the six tool validators.
    #
    # Every refusal names a field, never a value: an error message is operator-facing and
    # content-redacted, so a refused write cannot echo the remembered body back to the
    # model or into the diagnostic log [contracts: response_fields.error; plan §9].
    module Rules
      module_function

      def invalid!(detail, details = {})
        raise Kioku::Error.new("kioku.invalid_request", message: detail, details: details)
      end

      def unsupported!(detail, details = {})
        raise Kioku::Error.new("kioku.unsupported_operation", message: detail, details: details)
      end

      # The published schema is the whole accepted surface, so anything else is refused
      # rather than ignored.
      def only(arguments, permitted)
        unknown = arguments.keys - permitted
        return if unknown.empty?

        invalid!("unrecognized fields for this call: #{unknown.sort.join(', ')}")
      end

      def require_keys(arguments, required)
        missing = required.reject { |key| arguments.key?(key) }
        return if missing.empty?

        invalid!("required fields are missing: #{missing.sort.join(', ')}")
      end

      def text(arguments, key, max:)
        value = arguments[key]
        invalid!("#{key} must be a string") unless value.is_a?(String)
        invalid!("#{key} must be non-blank") if value.strip.empty?
        invalid!("#{key} exceeds #{max} characters") if value.length > max
        value
      end

      def list(arguments, key, min:, max:)
        value = arguments[key]
        invalid!("#{key} must be an array") unless value.is_a?(Array)
        invalid!("#{key} must carry between #{min} and #{max} entries") unless value.size.between?(min, max)
        value
      end

      def enum(arguments, key, allowed)
        value = arguments[key]
        invalid!("#{key} must be one of: #{allowed.join(', ')}") unless allowed.include?(value)
        value
      end

      def integer(arguments, key, minimum:)
        value = arguments[key]
        invalid!("#{key} must be an integer") unless value.is_a?(Integer)
        invalid!("#{key} must be at least #{minimum}") if value < minimum
        value
      end

      def object(arguments, key)
        value = arguments[key]
        invalid!("#{key} must be an object") unless value.is_a?(Hash)
        value
      end

      def typed_handles(arguments, key, min:, max:)
        entries = list(arguments, key, min: min, max: max)
        entries.each_with_index do |entry, index|
          invalid!("#{key}[#{index}] must be a typed handle") unless entry.is_a?(Hash)
          text(entry, "key", max: 512)
          invalid!("#{key}[#{index}].kind must be a string") unless entry["kind"].is_a?(String)
        end
        entries
      end

      # "an unvalidated name returns kioku.unsupported_operation"
      # [contracts: tools context_related].
      def edge_kinds(arguments, key, vocabulary)
        kinds = list(arguments, key, min: 1, max: 8)
        unvalidated = kinds.reject { |kind| vocabulary.include?(kind) }
        return kinds if unvalidated.empty?

        unsupported!("edge kinds outside the validated vocabulary: #{unvalidated.sort.join(', ')}")
      end

      def stringify(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), out| out[key.to_s] = stringify(item) }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end
  end
end
