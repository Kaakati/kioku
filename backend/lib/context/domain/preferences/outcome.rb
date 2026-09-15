# frozen_string_literal: true

module Context
  module Domain
    module Preferences
      # The result of resolving global guidance for one project.
      #
      # Nothing is silently dropped. A record that did not survive applicability,
      # validity, lifecycle or an exclusion appears in `excluded` with a reason;
      # an override the actor lacked the authority to apply appears in
      # `refused_overrides` rather than being ignored; and an equal-authority
      # disagreement appears in `unresolved_conflicts` while both records stay
      # effective and visible.
      class Outcome < Data.define(:effective, :excluded, :refused_overrides, :unresolved_conflicts)
        def initialize(effective:, excluded: [], refused_overrides: [], unresolved_conflicts: [])
          super
        end

        def any_unresolved_conflicts? = !unresolved_conflicts.empty?
        def mandatory = effective.select(&:mandatory_global?)
        def overridden = effective.select(&:overridden?)

        def to_wire
          {
            effective: effective.map(&:to_wire),
            excluded: excluded,
            refused_overrides: refused_overrides,
            unresolved_conflicts: unresolved_conflicts
          }
        end
      end
    end
  end
end
