# frozen_string_literal: true

module Context
  module Domain
    module Evidence
      # One resolved evidence reference, as the eligibility policy sees it.
      #
      # This is the output of a read (Context::Queries::Evidence::ResolveRefs)
      # flattened into plain values, so the policy that decides eligibility
      # performs no I/O of its own and is testable without a database.
      class Candidate < Data.define(
        :ref, :relation, :resolved, :evidence_key, :store_kind, :project_key,
        :availability, :deleted, :deletion_epoch, :source_anchor, :object_backed, :object_available
      )
        def initialize(ref:, relation:, resolved: false, evidence_key: nil, store_kind: nil,
                       project_key: nil, availability: nil, deleted: false, deletion_epoch: nil,
                       source_anchor: nil, object_backed: false, object_available: false)
          super
        end

        # A handle that did not resolve is reported the same way whether it does
        # not exist or belongs to a scope the caller cannot see (Plan §5.3).
        def unresolved? = !resolved
        def available? = availability == "available"
        def contradicting? = relation == "contradicts"

        # The anchor schema itself is a separate, not-yet-frozen Phase 0
        # deliverable; what is checked here is that an anchor, when present, is
        # a versioned structured object rather than free text.
        def anchor_valid?
          return true if source_anchor.nil?

          source_anchor.is_a?(Hash) && source_anchor["schema_version"].is_a?(String)
        end
      end
    end
  end
end
