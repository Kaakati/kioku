# frozen_string_literal: true

require_relative "../rules"
require_relative "../tool_contract"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_search]. The three retrieval mechanisms are the whole
      # set; mode=semantic and mode=hybrid are permanently unsupported values rather than
      # absent ones, so a caller that asks for them is told the mechanism does not exist
      # instead of being told to fix its spelling.
      class Search
        CONTRACT = ToolContract.new("context_search")

        # Recorded in the artifact so a conformance test can assert neither value is
        # accepted anywhere; referenced by no tool, which is why it is read from the
        # shared definitions rather than from this tool's own enum.
        REMOVED_MODES = Kioku::Contracts.definition("removed_retrieval_modes").fetch("enum").freeze

        def call(arguments:)
          CONTRACT.call(arguments: arguments, mutation: false) do
            refuse_removed_mode(arguments)
            refuse_unvalidated_edge_kinds(arguments)
            refuse_deep_expansion(arguments)
          end
        end

        private

        def refuse_removed_mode(arguments)
          return unless REMOVED_MODES.include?(arguments["mode"])

          Rules.unsupported!("embedding-based retrieval is out of scope for this contract",
                             "fields" => ["mode"])
        end

        def refuse_unvalidated_edge_kinds(arguments)
          allowed = CONTRACT.declares("properties", "edge_kinds", "items", "enum")
          Rules.unvalidated_edge_kinds!(arguments["edge_kinds"], allowed, "edge_kinds")
          Rules.unvalidated_edge_kinds!(Rules.at(arguments, "expand", "edge_kinds"), allowed,
                                        "expand.edge_kinds")
        end

        def refuse_deep_expansion(arguments)
          ceiling = CONTRACT.declares("properties", "expand", "properties", "hops", "maximum")
          Rules.hops_above_ceiling!(Rules.at(arguments, "expand", "hops"), ceiling, "expand.hops")
        end
      end
    end
  end
end
