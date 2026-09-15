# frozen_string_literal: true

require "time"

module Context
  module Domain
    module Preferences
      # Resolves which global engineering records actually govern one project.
      #
      # Plan §1.3, in order:
      #   1. Authority resolves before specificity.
      #   2. Within equal authority and an override-permitting policy, an
      #      explicit project exception beats a global default for its declared
      #      scope.
      #   3. A project assertion cannot defeat a higher-authority instruction,
      #      and relaxing a rule a user marked mandatory needs the authority to
      #      amend that rule.
      #   4. Unresolved equal-authority conflicts remain visible instead of
      #      being resolved by recency alone.
      #
      # Pure policy: every input is passed in, nothing is read, nothing is
      # written, and the clock is an argument.
      class Resolution
        def call(candidates:, overrides:, scope:, stack_profile:, now: Time.now.utc)
          state = { effective: [], excluded: [], refused: [] }
          applicable = applicable_overrides(overrides, scope, now)
          candidates.each { |candidate| consider(candidate, applicable, stack_profile, now, state) }
          effective, conflicts, demoted = resolve_conflicts(state[:effective])
          Outcome.new(
            effective: effective.freeze,
            excluded: (state[:excluded] + demoted).freeze,
            refused_overrides: state[:refused].freeze,
            unresolved_conflicts: conflicts.freeze
          )
        end

        private

        def consider(candidate, overrides, stack_profile, now, state)
          reason = ineligible_reason(candidate, stack_profile, now)
          return state[:excluded] << exclusion(candidate, reason) if reason

          apply_override(candidate, overrides.find { |override| override.targets?(candidate) }, state)
        end

        # Lifecycle first: only an active record governs. A proposed record stays
        # discoverable through search but is not policy.
        def ineligible_reason(candidate, stack_profile, now)
          return "not_governing_lifecycle" unless candidate.governing_lifecycle?
          return "outside_validity_interval" unless candidate.valid_at?(now)
          return "applicability_mismatch" unless candidate.applies_to?(stack_profile)

          nil
        end

        def applicable_overrides(overrides, scope, now)
          overrides.select do |override|
            override.project_key == scope.project_key && override.valid_at?(now) && override.covers?(scope)
          end
        end

        def apply_override(candidate, override, state)
          return state[:effective] << unoverridden(candidate) if override.nil?

          refusal = refusal_reason(candidate, override)
          if refusal
            state[:refused] << refused(override, refusal)
            return state[:effective] << unoverridden(candidate)
          end
          return state[:excluded] << exclusion(candidate, "excluded_by_project_override", override) if override.exclusion

          state[:effective] << overridden(candidate, override)
        end

        # Authority before specificity. An override pinned to a superseded
        # revision of the global record is refused rather than carried forward:
        # the exception was reasoned against wording that no longer stands.
        def refusal_reason(candidate, override)
          return "mandatory_global_requires_governing_authority" if candidate.mandatory && !AuthorityRank.governing?(override.authority)
          return "lower_authority_than_target" unless AuthorityRank.at_least?(override.authority, candidate.authority)
          return "target_revision_superseded" unless override.target_revision == candidate.revision

          nil
        end

        def unoverridden(candidate)
          EffectivePreference.new(
            **shared_attributes(candidate),
            body: candidate.body,
            override_status: candidate.mandatory ? "mandatory_global" : "none",
            override: nil
          )
        end

        def overridden(candidate, override)
          EffectivePreference.new(
            **shared_attributes(candidate),
            body: override.replacement_body || candidate.body,
            override_status: "overridden_in_project",
            override: override
          )
        end

        def shared_attributes(candidate)
          {
            memory_key: candidate.memory_key, revision: candidate.revision, category: candidate.category,
            authority: candidate.authority, mandatory: candidate.mandatory, conflict_key: candidate.conflict_key
          }
        end

        def exclusion(candidate, reason, override = nil)
          {
            memory_key: candidate.memory_key, revision: candidate.revision,
            reason: reason, override_id: override&.override_id
          }.freeze
        end

        def refused(override, reason)
          {
            override_id: override.override_id, project_key: override.project_key,
            target_memory_key: override.target_memory_key, target_revision: override.target_revision,
            authority: override.authority, reason: reason
          }.freeze
        end

        # Within a declared conflict group the highest authority governs and the
        # rest are demoted. When the top authority is tied, every tied record
        # stays effective and is marked unresolved: the conflict is surfaced,
        # not settled by which one was recorded last.
        def resolve_conflicts(effective)
          grouped = effective.group_by { |item| item.conflict_key.nil? ? nil : [item.category, item.conflict_key] }
          kept = grouped.delete(nil) || []
          conflicts = []
          demoted = []
          grouped.each_value do |group|
            winners, losers = split_by_authority(group)
            demoted.concat(losers.map { |item| exclusion(item, "lower_authority_in_declared_conflict") })
            conflicts << conflict_entry(winners) if winners.length > 1
            kept.concat(winners.length > 1 ? winners.map { |item| item.with(unresolved_conflict: true) } : winners)
          end
          [kept, conflicts, demoted]
        end

        def split_by_authority(group)
          top = AuthorityRank.highest(group.map(&:authority))
          group.partition { |item| item.authority == top }
        end

        def conflict_entry(winners)
          {
            category: winners.first.category, conflict_key: winners.first.conflict_key,
            authority: winners.first.authority, memory_keys: winners.map(&:memory_key).freeze,
            resolution: "unresolved_equal_authority"
          }.freeze
        end
      end
    end
  end
end
