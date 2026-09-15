# frozen_string_literal: true

module Context
  module Domain
    module Preferences
      # One global record as it actually applies to this project, after
      # authority and any project exception have been taken into account.
      #
      # The override is carried alongside rather than folded away, so a reader
      # can always see that a shared preference was locally excepted, by whom
      # and why. unresolved_conflict is true when this record is tied at the
      # top authority with another record in the same declared conflict group:
      # both stay visible instead of one being picked by recency.
      class EffectivePreference < Data.define(
        :memory_key, :revision, :category, :authority, :mandatory,
        :body, :override_status, :override, :conflict_key, :unresolved_conflict
      )
        def initialize(memory_key:, revision:, category:, authority:, body:, override_status:,
                       mandatory: false, override: nil, conflict_key: nil, unresolved_conflict: false)
          super
        end

        def overridden? = override_status == "overridden_in_project"
        def mandatory_global? = override_status == "mandatory_global"

        def to_wire
          to_h.except(:override).merge(
            override: override && {
              override_id: override.override_id,
              project_key: override.project_key,
              target_revision: override.target_revision,
              reason: override.reason,
              authority: override.authority
            }
          )
        end
      end
    end
  end
end
