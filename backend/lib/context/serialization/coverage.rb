# frozen_string_literal: true

module Context
  module Serialization
    # What this answer actually covered.
    #
    # completeness_label is fixed at known_within_indexed_coverage: the contract
    # has no value meaning "complete for the repository" (Plan invariant 6).
    # Coverage can be partial in the evidence sense — declared gaps present —
    # without the response status changing, so callers branch on status for
    # delivery and on coverage for trust.
    class Coverage < Data.define(
      :state, :declared_input_set, :considered, :returned, :truncated_at, :gaps, :omitted
    )
      COMPLETENESS_LABEL = "known_within_indexed_coverage"

      def initialize(state:, declared_input_set:, considered: 0, returned: 0,
                     truncated_at: nil, gaps: [], omitted: { count: 0, reason: nil })
        super
      end

      def self.complete(declared_input_set:, considered: 0, returned: 0)
        new(state: "complete_for_declared_set", declared_input_set: declared_input_set,
            considered: considered, returned: returned)
      end

      def self.partial(declared_input_set:, gaps:, considered: 0, returned: 0, truncated_at: nil, omitted_count: 0, omitted_reason: nil)
        new(state: "partial", declared_input_set: declared_input_set, considered: considered,
            returned: returned, truncated_at: truncated_at, gaps: gaps,
            omitted: { count: omitted_count, reason: omitted_reason })
      end

      # Adding a gap never silently shortens a result: it moves the coverage
      # state to partial so the omission is visible.
      def with_gap(kind:, detail:, count: 1)
        Contracts::Validator.enum!(kind, field: "coverage.gaps.kind", allowed: Contracts::Vocabulary.coverage_gap_kinds)
        with(state: "partial", gaps: gaps + [{ kind: kind, detail: detail, count: count }.freeze])
      end

      def partial? = state == "partial"

      def to_wire
        {
          "state" => state,
          "declared_input_set" => stringify(declared_input_set),
          "counts" => { "considered" => considered, "returned" => returned, "truncated_at" => truncated_at },
          "gaps" => gaps.map { |gap| stringify(gap) },
          "omitted_results" => stringify(omitted),
          "completeness_label" => COMPLETENESS_LABEL
        }
      end

      def stringify(value)
        value.is_a?(Hash) ? value.transform_keys(&:to_s) : value
      end
      private :stringify
    end
  end
end
