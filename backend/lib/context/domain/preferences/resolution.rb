# frozen_string_literal: true

module Context
  module Domain
    module Preferences
      # What Resolve decided, per topic.
      #
      # An unresolved equal-authority conflict is reported rather than settled:
      # `effective_for` is nil and the competing keys stay visible (plan 1.3).
      class Resolution
        Decision = Struct.new(:rule, :override_status, :conflicting_rule_keys, keyword_init: true)

        attr_reader :rejected_overrides

        def initialize(decisions:, rejected_overrides: [])
          @decisions = decisions
          @rejected_overrides = rejected_overrides
          freeze
        end

        def effective_for(topic:)
          decision_for(topic)&.rule
        end

        def unresolved_conflict?(topic:)
          conflicting_rule_keys(topic: topic).any?
        end

        def conflicting_rule_keys(topic:)
          decision_for(topic)&.conflicting_rule_keys || []
        end

        def override_status_for(topic:)
          decision_for(topic)&.override_status || :none
        end

        private

        def decision_for(topic)
          @decisions[topic.to_sym]
        end
      end
    end
  end
end
