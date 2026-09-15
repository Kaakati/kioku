# frozen_string_literal: true

require_relative "../errors"

module Kioku
  module Mcp
    # The refusal primitives the six tool validators share.
    #
    # Shape, enum, bound and closure checking is no longer here: it is one structural
    # pass over the shared artifact's own schema (Kioku::Contracts::Schema). What remains
    # are the refusals a schema cannot express, because they carry a wire name of their
    # own — a value the contract declares PERMANENTLY unsupported is not a typo to be
    # corrected, and a caller told kioku.invalid_request would go looking for a spelling
    # mistake instead of learning the mechanism does not exist.
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

      # "an unvalidated name returns kioku.unsupported_operation"
      # [contracts: tools context_related / context_search x-kioku-refusals].
      def unvalidated_edge_kinds!(values, allowed, field)
        return unless values.is_a?(Array)
        return if values.all? { |kind| allowed.include?(kind) }

        unsupported!("#{field} names an edge kind outside the validated vocabulary",
                     "fields" => [field])
      end

      # "Covers ... hops greater than 2" [contracts: errors kioku.unsupported_operation].
      # A third hop is a request for a mechanism this contract does not have, not a bound
      # to nudge upward.
      def hops_above_ceiling!(value, ceiling, field)
        return unless value.is_a?(Integer) && ceiling.is_a?(Integer) && value > ceiling

        unsupported!("#{field} above #{ceiling} is not supported by this contract",
                     "fields" => [field])
      end

      # These refusals run BEFORE the structural pass, so a nested value may still be any
      # shape a caller sent. Reaching into it must not raise instead of refusing.
      def at(payload, *path)
        path.reduce(payload) { |node, key| node.is_a?(Hash) ? node[key] : nil }
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
