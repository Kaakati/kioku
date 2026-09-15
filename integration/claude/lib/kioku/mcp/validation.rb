# frozen_string_literal: true

module Kioku
  module Mcp
    # An input schema that still publishes its `required` list in tools/list but
    # does not let the SDK answer a violation itself.
    #
    # The SDK's own missing-required guard replies with an untyped sentence.
    # Kioku answers every contract violation with a frozen wire name, so the
    # guard is delegated to Validator below and this reports nothing missing.
    class ContractSchema < ::MCP::Tool::InputSchema
      def missing_required_arguments(_arguments)
        []
      end
    end

    # Validates tool arguments against the frozen input schema and maps every
    # failure to kioku.invalid_request. Schemas are compiled once per tool.
    class Validator
      MAX_DETAIL_BYTES = 1_024

      def initialize
        @schemas = {}
      end

      def schema_for(tool)
        @schemas[tool] ||= ContractSchema.new(Kioku::Schemas.input_schema(tool))
      end

      def validate!(tool, arguments)
        schema_for(tool).validate_arguments(arguments)
        arguments
      rescue ::MCP::Tool::InputSchema::ValidationError => e
        raise Kioku.invalid_request(
          "tool arguments failed contract validation",
          { "tool" => tool, "detail" => detail(e) }
        )
      end

      private

      # The validator's own text, bounded. It is kept as one string because the
      # underlying messages are comma-joined and splitting them fabricates
      # violations that were never reported.
      def detail(error)
        error.message.delete_prefix("Invalid arguments: ").byteslice(0, MAX_DETAIL_BYTES).to_s.scrub
      end
    end
  end
end
