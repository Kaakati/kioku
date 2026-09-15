# frozen_string_literal: true

module Context
  module Domain
    module Evidence
      # Decides which requested evidence links may back a memory revision.
      #
      # The core enforces at least one appropriate evidence link before the
      # memory-save transaction commits (Research Appendix A). Eligibility is
      # about scope, availability, deletion state and anchor shape — it says
      # nothing about whether the statement is true. An eligible link is not
      # support; claim support stays a separate, separately attributed label.
      class Eligibility
        # One accepted link. restricted_source marks project-owned evidence
        # carried by a global record: the provenance link is kept, but it grants
        # no other project access to that evidence (Plan §1.3).
        Accepted = Data.define(:ref, :relation, :evidence_key, :restricted_source)
        Rejected = Data.define(:ref, :relation, :reason)

        Outcome = Data.define(:accepted, :rejected) do
          def eligible? = !accepted.empty?
          def rejected_contradicting = rejected.select { |item| item.relation == "contradicts" }
        end

        def call(candidates:, destination:)
          accepted = []
          rejected = []
          candidates.each do |candidate|
            reason = rejection_reason(candidate, destination)
            if reason
              rejected << Rejected.new(ref: candidate.ref, relation: candidate.relation, reason: reason)
            else
              accepted << Accepted.new(ref: candidate.ref, relation: candidate.relation,
                                       evidence_key: candidate.evidence_key,
                                       restricted_source: restricted_source?(candidate, destination))
            end
          end
          Outcome.new(accepted: accepted.freeze, rejected: rejected.freeze)
        end

        private

        # Ordered gates: not_found, deleted, unavailable, scope_mismatch,
        # anchor_invalid. The first failing gate names the rejection, and the
        # codes are the frozen enum (envelope.v1.json evidence_rejection_reason).
        def rejection_reason(candidate, destination)
          return "not_found" if candidate.unresolved?
          return "deleted" if candidate.deleted
          return "unavailable" unless candidate.available?
          return "unavailable" if candidate.object_backed && !candidate.object_available
          return "scope_mismatch" unless scope_permits?(candidate, destination)
          return "anchor_invalid" unless candidate.anchor_valid?

          nil
        end

        # A project record may link installation-owned evidence or evidence its
        # own project owns, never another project's. A global record may carry a
        # provenance link to project evidence, and that link is marked restricted.
        def scope_permits?(candidate, destination)
          return true if candidate.project_key.nil?
          return true if destination.global?

          candidate.project_key == destination.project_key
        end

        def restricted_source?(candidate, destination)
          destination.global? && !candidate.project_key.nil?
        end
      end
    end
  end
end
