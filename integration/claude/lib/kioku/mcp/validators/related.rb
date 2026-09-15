# frozen_string_literal: true

require_relative "../rules"
require_relative "../tool_contract"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_related]. edge_kinds is required rather than defaulted,
      # so no call can request an untyped walk, and the hop ceiling is a contract limit
      # rather than a tuning knob: "Covers ... hops > 2"
      # [contracts: errors kioku.unsupported_operation].
      class Related
        CONTRACT = ToolContract.new("context_related")

        def call(arguments:)
          CONTRACT.call(arguments: arguments, mutation: false) do
            Rules.unvalidated_edge_kinds!(arguments["edge_kinds"],
                                          CONTRACT.declares("properties", "edge_kinds", "items", "enum"),
                                          "edge_kinds")
            Rules.hops_above_ceiling!(arguments["max_hops"],
                                      CONTRACT.declares("properties", "max_hops", "maximum"),
                                      "max_hops")
          end
        end
      end
    end
  end
end
