# frozen_string_literal: true

require_relative "../tool_contract"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_fetch]. Batches are bounded at both ends: an empty batch
      # is as malformed as an oversized one, because a fetch names what it wants.
      #
      # Every refusal this tool can make at the boundary is structural, so the published
      # schema is the whole of it. The two conditions its x-kioku-refusals block names —
      # a handle that does not resolve, and one that was deleted, expired, purged or
      # redacted — are the core's to answer; the adapter holds no storage authority and
      # cannot tell them apart without asking.
      class Fetch
        CONTRACT = ToolContract.new("context_fetch")

        def call(arguments:)
          CONTRACT.call(arguments: arguments, mutation: false)
        end
      end
    end
  end
end
