# frozen_string_literal: true

module Context
  module Domain
    module Preferences
      # A stored project exception to a global record.
      #
      # An override is a link to the affected global preference plus its reason
      # and origin. It never modifies the global record, and its effect is
      # limited to the scope it declares: an empty declared scope means the
      # whole project, and a narrower one applies only where it says.
      class Override < Data.define(
        :override_id, :project_key, :target_memory_key, :target_revision, :authority,
        :replacement_body, :exclusion, :reason, :valid_from, :valid_until, :declared_scope
      )
        SCOPE_DIMENSIONS = %w[repository_keys worktree_keys task_keys].freeze

        def initialize(project_key:, target_memory_key:, target_revision:, authority:, reason:,
                       override_id: nil, replacement_body: nil, exclusion: false,
                       valid_from: nil, valid_until: nil, declared_scope: {})
          super
        end

        def valid_at?(now)
          return false if valid_from && valid_from > now

          valid_until.nil? || valid_until > now
        end

        # Applies where it says it applies. A dimension the override does not
        # declare is unconstrained; a dimension it declares must match the
        # request's scope, and an unstated request dimension does not match a
        # stated override dimension.
        def covers?(scope)
          SCOPE_DIMENSIONS.all? do |dimension|
            declared = Array(declared_scope[dimension] || declared_scope[dimension.to_sym])
            declared.empty? || declared.include?(scope_value(scope, dimension))
          end
        end

        def scope_value(scope, dimension)
          case dimension
          when "repository_keys" then scope.repository_key
          when "worktree_keys" then scope.worktree_key
          else scope.task_key
          end
        end
        private :scope_value

        def targets?(candidate)
          candidate.memory_key == target_memory_key
        end
      end
    end
  end
end
