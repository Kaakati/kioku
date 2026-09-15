# frozen_string_literal: true

require_relative "../rules"
require_relative "../vocabulary"
require_relative "../../envelope"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_feedback]. An objection names the exact revision it
      # disputes: "A head-only reference returns kioku.invalid_request, because a dispute
      # must name what was actually disputed." The objection never rewrites the target's
      # support or its delivery effect, so neither is an accepted input.
      class Feedback
        PERMITTED = %w[envelope target action reason evidence].freeze

        MAX_REASON = 4096
        MAX_KEY = 512

        def call(arguments:)
          Rules.only(arguments, PERMITTED)
          envelope = Kioku::Envelope.parse_request(arguments["envelope"], mutation: true)
          validate_target(arguments)
          Rules.enum(arguments, "action", Vocabulary::FEEDBACK_ACTIONS)
          Rules.text(arguments, "reason", max: MAX_REASON)
          envelope
        end

        private

        def validate_target(arguments)
          target = Rules.object(arguments, "target")
          Rules.text(target, "memory_key", max: MAX_KEY)
          Rules.integer(target, "revision", minimum: 1)
        end
      end
    end
  end
end
