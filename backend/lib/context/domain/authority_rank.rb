# frozen_string_literal: true

module Context
  module Domain
    # The one place authority is ordered.
    #
    # Two things are fixed by the source documents and are not negotiable here:
    # a user's decisions, constraints and corrections are the governing
    # authority, and assistant inference never becomes user policy by
    # repetition (Plan §1.3, §1.4). The documents do not order the remaining
    # values against each other, so the rest of this ladder is Kioku's own
    # declared ordering, recorded here rather than scattered through comparisons:
    #
    #   user   > system > tool > assistant > imported
    #
    # `imported` sits at the bottom deliberately. Imported document text,
    # source comments and tool output are evidence data; they cannot grant
    # authority or instruct the core (Plan §6.3).
    module AuthorityRank
      ORDER = %w[imported assistant tool system user].freeze
      GOVERNING = "user"

      module_function

      def rank(authority)
        ORDER.index(authority) ||
          raise(Errors::InvalidRequest.new(details: { field: "authority", reason: "not_in_enum" }))
      end

      def outranks?(candidate, other) = rank(candidate) > rank(other)
      def same_rank?(candidate, other) = rank(candidate) == rank(other)
      def at_least?(candidate, other) = rank(candidate) >= rank(other)
      def governing?(authority) = authority == GOVERNING

      # The highest authority present, or nil for an empty set.
      def highest(authorities)
        authorities.max_by { |authority| rank(authority) }
      end

      def tied_at_top(authorities)
        top = highest(authorities)
        top.nil? ? [] : authorities.select { |authority| authority == top }
      end
    end
  end
end
