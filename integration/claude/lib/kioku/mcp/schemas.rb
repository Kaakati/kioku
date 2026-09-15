# frozen_string_literal: true

require_relative "../contracts"

module Kioku
  module Mcp
    # "The MCP tool surface stays at six tools" [contracts: envelope.notes; plan §6.2].
    # Project registration and root management stay on the operator/UI setup APIs and are
    # deliberately absent from this surface.
    #
    # The schemas are the shared artifact's own resolved, build-pruned result, published
    # verbatim. The hand-written transcription this replaced was a second description of
    # one contract, and it had already drifted: it omitted nine context_remember inputs
    # the contract names, so a model could not see that they exist (D7), and it declared
    # the envelope's request_id as "36 characters" with no UUIDv7 pattern at all (D3).
    module Schemas
      module_function

      def all
        Kioku::Contracts.resolved_tools
      end

      # The description a model reads is the schema's own, for the same reason: a tool
      # described here and specified there is two documents to keep in step.
      def description(tool)
        Kioku::Contracts.tool_schema(tool).fetch("description")
      end
    end
  end
end
