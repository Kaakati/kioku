# frozen_string_literal: true

require_relative "../tool_contract"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_feedback]. An objection names the exact revision it
      # disputes: "A head-only reference returns kioku.invalid_request, because a dispute
      # must name what was actually disputed" — which is `target.required = [memory_key,
      # revision]` in the published schema, not a rule kept here.
      #
      # The objection never rewrites the target's support or its delivery effect, so
      # neither is a declared property anywhere and closure refuses both.
      class Feedback
        CONTRACT = ToolContract.new("context_feedback")

        def call(arguments:)
          CONTRACT.call(arguments: arguments, mutation: true)
        end
      end
    end
  end
end
