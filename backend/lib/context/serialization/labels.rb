# frozen_string_literal: true

module Context
  module Serialization
    # The six evidence dimensions, kept separate.
    #
    # Research §5 forbids collapsing these into one verified boolean or a
    # confidence float, so this type has no #verified?, no #trusted? and no
    # aggregate score. All six travel together on every item:
    #
    #   authority     who said it
    #   lifecycle     whether it still stands
    #   availability  whether its content can still be produced
    #   applicability whether it was checked against current source
    #   claim_support whether anything assessed it, and who did
    #   coverage      what the answer that produced it actually covered
    #
    # relevance is a BM25 score and sits in its own field. It is never claim
    # support and never confidence in truth.
    class Labels < Data.define(
      :authority, :lifecycle, :availability, :applicability,
      :claim_support, :coverage, :dispute, :override_status, :relevance
    )
      UNASSESSED = { "value" => "unassessed", "evaluator" => nil, "attributed_at" => nil, "rationale_ref" => nil }.freeze
      NO_DISPUTE = { "has_open_dispute" => false, "count" => 0, "objection_handles" => [] }.freeze

      def initialize(authority:, lifecycle:, availability:, applicability:, coverage:,
                     claim_support: UNASSESSED, dispute: NO_DISPUTE, override_status: "none", relevance: nil)
        super
      end

      # A save records a conclusion; it never establishes support. The default
      # after a write is therefore unassessed, and the default applicability is
      # `unknown` unless a host check actually succeeded inside this deadline.
      def self.for_saved_revision(authority:, lifecycle:, coverage:, override_status: "none")
        new(authority: authority, lifecycle: lifecycle, availability: "available",
            applicability: "unknown", coverage: coverage, override_status: override_status)
      end

      def validate!
        vocabulary = Contracts::Vocabulary
        Contracts::Validator.enum!(authority, field: "authority", allowed: vocabulary.authorities)
        Contracts::Validator.enum!(lifecycle, field: "lifecycle", allowed: vocabulary.lifecycles)
        Contracts::Validator.enum!(availability, field: "availability", allowed: vocabulary.availabilities)
        Contracts::Validator.enum!(applicability, field: "applicability", allowed: vocabulary.applicabilities)
        Contracts::Validator.enum!(claim_support["value"], field: "claim_support.value", allowed: vocabulary.claim_support_values)
        Contracts::Validator.enum!(override_status, field: "override_status", allowed: vocabulary.override_statuses)
        self
      end

      def to_wire
        {
          "authority" => authority,
          "lifecycle" => lifecycle,
          "availability" => availability,
          "applicability" => applicability,
          "claim_support" => claim_support,
          "coverage" => coverage.to_wire,
          "dispute" => dispute,
          "override_status" => override_status,
          "relevance" => relevance
        }
      end
    end
  end
end
