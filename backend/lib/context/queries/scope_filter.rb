# frozen_string_literal: true

module Context
  module Queries
    # Narrows a relation to what the authorized scope permits.
    #
    # This runs before candidate limits, ordering and ranking on every route, so
    # another project's records can never occupy a slot an eligible record
    # needed (Plan §7.2 step 5). Applying it after a limit would produce a
    # smaller, quietly wrong answer, which is why #call takes the unlimited
    # relation and the caller applies the limit afterwards.
    #
    # The relation must expose store_kind and project_key columns; those two
    # carry memory ownership, and ownership is a domain and authorization
    # boundary rather than a separate database (Plan §5.1).
    class ScopeFilter
      def call(relation:, authorized_scope:)
        table = relation.klass.arel_table
        case authorized_scope.store
        when "project" then relation.where(project_predicate(table, authorized_scope))
        when "global" then relation.where(table[:store_kind].eq("global"))
        else relation.where(table[:store_kind].eq("global").or(project_predicate(table, authorized_scope)))
        end
      end

      private

      # Other projects' records — and their code, graph nodes and raw
      # provenance — are excluded unless their project was named as an
      # explicitly granted cross-project scope.
      def project_predicate(table, authorized_scope)
        table[:store_kind].eq("project").and(table[:project_key].in(authorized_scope.project_keys))
      end
    end
  end
end
