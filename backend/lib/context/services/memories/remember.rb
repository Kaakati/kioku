# frozen_string_literal: true

module Context
  module Services
    module Memories
      # Commit one evidence-linked durable memory revision (plan 4.1's reference
      # use case, plan 7.1 capture and durable save).
      #
      # The order below is the contract, not an implementation detail:
      #
      #   1. Validate the destination, the authority and the request contract.
      #   2. Answer a replay from its prior receipt before doing any work.
      #   3. Stage every required object BEFORE the transaction opens, so no
      #      available evidence reference can commit ahead of its bytes
      #      (invariant 3).
      #   4. Lock and check the head, then commit event, revision, head, search
      #      projection, receipt and outbox event in one short transaction
      #      (plan 7.1 step 5). `saved` is returned only after that commit
      #      (invariant 2).
      #
      # The transaction requires its own savepoint rather than joining a caller's:
      # a rollback here must undo this use case and nothing else. Unexpected
      # exceptions are not caught — a failed save is never reported as a
      # successful one (plan 4.1).
      class Remember
        OUTBOX_EVENT_TYPE = "kioku.memory.revision_committed"

        def initialize(object_store:, outbox:, writer: Storage::MemoryWriter.new)
          @object_store = object_store
          @outbox = outbox
          @writer = writer
        end

        def call(actor:, envelope:, kind:, destination:, title:, body:, evidence:,
                 memory_key: nil, applicability: nil, mandatory: false, lifecycle: nil,
                 received_body: nil)
          remember(
            Request.new(actor: actor, envelope: envelope, kind: kind,
                        destination: destination, title: title, body: body,
                        evidence: evidence, memory_key: memory_key,
                        applicability: applicability, mandatory: mandatory,
                        lifecycle: lifecycle, received_body: received_body)
          )
        rescue Errors::Error => error
          Result.refused(error)
        end

        private

        attr_reader :object_store, :outbox, :writer

        def remember(request)
          authorize!(request)
          replay(request) || commit(request, stage_evidence(request))
        end

        # --- validation and authority ----------------------------------------

        def authorize!(request)
          binding_unresolved! if request.project? && request.project_key.blank?
          invalid!("title") if request.title.blank?
          invalid!("body") if request.body.blank?
          authorize_global!(request) if request.global?
          return unless request.mandatory? && !request.actor.user?

          raise Errors::AuthorityViolation.new(
            "mandatory is user authority only",
            details: { field: "mandatory", authority: request.authority.to_s }
          )
        end

        # A global record without applicability conditions is refused: a reusable
        # statement with no declared limits is not reusable (plan 1.3).
        def authorize_global!(request)
          invalid!("applicability") if request.applicability_conditions.blank?
          invalid!("destination.category") if request.category.blank?
        end

        # --- idempotency -----------------------------------------------------

        # Plan 7.1: repeating the same idempotency key and payload returns the
        # prior receipt; a different payload conflicts and writes nothing. The
        # key is actor-scoped (frozen contract), so the lookup is too: another
        # actor's receipt is not this caller's outcome and is not this caller's
        # to be shown.
        def replay(request)
          record = receipt_for(request)
          record && outcome_of(record, request)
        end

        def receipt_for(request)
          writer.receipt_for(actor: request.actor,
                             idempotency_key: request.envelope.idempotency_key)
        end

        # What this caller's own committed receipt means for this call.
        def outcome_of(record, request)
          # E1. Both sides of this comparison are core-computed: the stored receipt
          # holds the digest of the content that actually committed, and the incoming
          # one is recomputed from the content that actually arrived. Comparing the
          # caller's ASSERTED digest here was the defect — it let a stale assertion buy
          # a `saved` for content the core never stored, and made identical content
          # under a different assertion look like a conflict.
          unless record.request_digest == request.computed_digest
            raise Errors::IdempotencyConflict.new(
              "the idempotency key was reused with a different request digest",
              details: { receipt_id: record.receipt_id, request_digest: record.request_digest }
            )
          end

          Result.replayed(record: record, receipt: Receipt.new(record: record, replayed: true),
                          head_revision: writer.head_revision_of(record.memory_key))
        end

        # --- evidence --------------------------------------------------------

        # Invariant 3: required object bytes are durably stored before an
        # available evidence reference commits, so staging happens here, outside
        # and before the canonical transaction.
        def stage_evidence(request)
          staged = request.evidence.map { |entry| stage(entry) }
          return staged if staged.any? { |entry| entry[:durable] }

          raise Errors::EvidenceRequired.new(
            "no supplied evidence link is eligible",
            details: { requested_evidence: staged.map { |entry| entry[:ref] } }
          )
        end

        # D4. A ref names exactly one of the three keys the shared schema declares.
        # Naming none, or naming two, is genuinely ambiguous — the core would have to
        # guess which reference the caller meant — so that stays kioku.invalid_request.
        #
        # A WELL-FORMED ref this build cannot resolve is not a malformed request. It is
        # reported per entry in evidence_rejected with a reason from the contract's own
        # enum, because answering kioku.invalid_request to a caller that sent exactly
        # what the contract specifies is the same dishonesty D1 removed from status.
        # Eligibility still decides whether the write commits at all: an empty eligible
        # set is kioku.evidence_required, which a caller branches on differently —
        # add evidence, rather than fix the request.
        REF_KEYS = %i[evidence_key object_key event_key].freeze

        def stage(entry)
          fields = entry.to_h.transform_keys(&:to_sym)
          ref = fields[:ref].to_h.transform_keys(&:to_sym)
                      .slice(*REF_KEYS).reject { |_, value| value.blank? }
          invalid!("evidence.ref") unless ref.size == 1

          relation = (fields[:relation] || :supports).to_sym
          return stage_object(ref, relation) if ref.key?(:object_key)

          # This phase has no resolver for an evidence_key or event_key, so the handle
          # is unresolvable here. That is `not_found`, not a malformed request.
          { ref: ref, relation: relation, durable: false, reason: :not_found }
        end

        # Unavailable bytes and an unresolvable handle are different reasons;
        # collapsing them would send an operator looking in the wrong place.
        def stage_object(ref, relation)
          durable = object_store.stage(object_key: ref[:object_key]).durable?

          { ref: ref, relation: relation, durable: durable,
            reason: durable ? nil : :unavailable }
        end

        # --- canonical commit ------------------------------------------------

        def commit(request, staged)
          accepted, rejected = staged.partition { |entry| entry[:durable] }

          ActiveRecord::Base.transaction(requires_new: true) do
            memory = writer.append(request: request, head: checked_head(request), evidence: accepted)
            receipt = Receipt.new(record: writer.write_receipt(request: request, memory: memory),
                                  replayed: false)

            Result.committed(
              memory: memory, revision: memory.current_revision, request: request,
              receipt: receipt, outbox_event_id: emit(memory),
              evidence_accepted: accepted.map { |entry| entry.slice(:ref, :relation) },
              # D4. Each entry carries the reason staging established. Hardcoding
              # :unavailable here reported an unresolvable handle as missing bytes.
              evidence_rejected: rejected.map { |entry| entry.slice(:ref, :reason) }
            )
          end
        rescue ActiveRecord::RecordNotUnique => error
          arbitrate(request, error)
        end

        # Plan 9's stack criterion: "Concurrent PostgreSQL writes cannot duplicate
        # revisions/receipts." Two creates that share a key both pass the replay
        # lookup, both build a memory, and the receipt's unique index refuses one
        # of them — the only arbiter there is, since a CREATE has no head to lock.
        # The loser's whole transaction has already rolled back by the time this
        # runs, so the honest answer is the committed receipt's: a replay, or the
        # conflict a different payload earns. ActiveRecord::RecordNotUnique is not
        # a kioku.* code and would otherwise reach the caller as a bare 500.
        def arbitrate(request, error)
          record = receipt_for(request)
          raise error if record.nil?

          outcome_of(record, request)
        end

        # Invariant 4: a stale writer fails its expected-revision check and
        # nothing is written, not even a receipt.
        def checked_head(request)
          return nil if request.memory_key.blank?

          memory = writer.locked_head(request.memory_key)
          raise Errors::HandleUnresolved, "no such memory" if memory.nil?
          return memory if memory.current_revision == request.expected_revision

          raise Errors::RevisionConflict.new(
            "the memory head moved",
            details: { current_revision: memory.current_revision,
                       current_head: memory.current_revision,
                       target_key: memory.memory_key }
          )
        end

        # Plan 5.1: an event and its canonical outbox rows commit together, so
        # this participates in the transaction above and never opens its own.
        #
        # The work key names the change being announced rather than the row that
        # announces it, so a reconciliation loop that re-records accepted work
        # collides instead of scheduling a second job for the same revision.
        def emit(memory)
          outbox.record(
            event_type: OUTBOX_EVENT_TYPE,
            work_key: "#{memory.memory_key}:#{memory.current_revision}",
            payload: { memory_key: memory.memory_key, revision: memory.current_revision,
                       store_kind: memory.store_kind },
            project_key: memory.project_key
          )
        end

        # --- refusals --------------------------------------------------------

        def invalid!(field)
          raise Errors::InvalidRequest.new("the request failed contract validation",
                                           details: { fields: [field] })
        end

        # Invariant 11: a missing project binding is surfaced as setup state and
        # is never read as permission to write globally.
        def binding_unresolved!
          raise Errors::ProjectBindingUnresolved.new(
            "the project binding is missing or unregistered",
            details: { setup_required: true }
          )
        end
      end
    end
  end
end
