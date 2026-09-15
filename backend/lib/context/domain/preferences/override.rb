# frozen_string_literal: true

module Context
  module Domain
    module Preferences
      # A project's declared exception to a rule. Plan 1.3: overrides are stored
      # as links to the affected preference and retain their reason and origin;
      # the targeted record is never modified to express one project's exception.
      class Override
        attr_reader :key, :target_rule_key, :project_key, :authority,
                    :replacement_statement, :exclusion, :reason, :recorded_at

        def initialize(key:, target_rule_key:, project_key:, authority:,
                       replacement_statement: nil, exclusion: false,
                       reason: nil, recorded_at: nil)
          @key = key
          @target_rule_key = target_rule_key
          @project_key = project_key
          @authority = authority.to_sym
          @replacement_statement = replacement_statement
          @exclusion = exclusion
          @reason = reason
          @recorded_at = recorded_at
          freeze
        end

        def exclusion?
          exclusion
        end
      end
    end
  end
end
