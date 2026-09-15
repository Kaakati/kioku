# frozen_string_literal: true

require "mcp"

module Kioku
  module Mcp
    # The published input schema for one tool.
    #
    # The Kioku contract validator is the single authority for refusals, so that every
    # refused call carries its frozen wire name — kioku.invalid_request,
    # kioku.unsupported_operation, kioku.evidence_required or
    # kioku.project_binding_unresolved — in an envelope a caller can branch on. The SDK's
    # generic required-argument pre-check answers with untyped prose and would shadow that
    # for the one case it covers, so it is disabled here rather than left to win the race.
    # The schema itself is published unchanged.
    class ContractSchema < ::MCP::Tool::InputSchema
      def missing_required_arguments(_arguments)
        []
      end
    end
  end
end
