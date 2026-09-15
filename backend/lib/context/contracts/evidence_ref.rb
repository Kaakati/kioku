# frozen_string_literal: true

module Context
  module Contracts
    # One requested evidence link: what is being pointed at, and how it relates
    # to the statement being recorded.
    #
    # `contradicts` is a first-class relation. Contrary evidence is never
    # dropped to make a record look stronger, and a rejected contradicting link
    # is reported rather than silently omitted.
    class EvidenceRef < Data.define(:ref, :relation)
      def self.parse(payload, field:)
        body = Validator.hash!(Validator.deep_stringify(payload), field: field)
        Validator.reject_unknown!(body, allowed: %w[ref relation], field: field)
        new(
          ref: TypedHandle.parse(Validator.required(body, "ref", field: "#{field}.ref"), field: "#{field}.ref"),
          relation: Validator.enum!(Validator.required(body, "relation", field: "#{field}.relation"),
                                    field: "#{field}.relation", allowed: Vocabulary.evidence_relations)
        )
      end

      def self.parse_list(payload, field:, min:, max:)
        Validator.array!(Validator.deep_stringify(payload || []), field: field, min: min, max: max)
                 .each_with_index.map { |item, index| parse(item, field: "#{field}[#{index}]") }
                 .freeze
      end

      def contradicting? = relation == "contradicts"
      def to_wire = { "ref" => ref.to_h.transform_keys(&:to_s), "relation" => relation }
    end
  end
end
