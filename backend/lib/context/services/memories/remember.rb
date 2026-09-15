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
                 memory_key: nil, applicability: nil, mandatory: false, lifecycle: nil)
          remember(
            Request.new(actor: actor, envelope: envelope, kind: kind,
                        destination: destination, title: title, body: body,
                        evidence: evidence, memory_key: memory_key,
                        applicability: applicability, mandatory: mandatory,
                        lifecycle: lifecycle)
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
        # prior receipt; a different payload conflicts and writes nothing.
        def replay(request)
          record = writer.receipt_for(request.envelope.idempotency_key)
          return nil if record.nil?
          unless record.request_digest == request.envelope.request_digest
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

        # Only object references are staged. An evidence_key or event_key ref is
        # a contract shape this phase does not implement, and is refused rather
        # than silently dropped from the eligibility count.
        def stage(entry)
          fields = entry.to_h.transform_keys(&:to_sym)
          object_key = fields[:ref].to_h.transform_keys(&:to_sym)[:object_key]
          invalid!("evidence.ref.object_key") if object_key.blank?

          {
            ref: { object_key: object_key },
            relation: (fields[:relation] || :supports).to_sym,
            durable: object_store.stage(object_key: object_key).durable?
          }
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
              evidence_rejected: rejected.map { |entry| { ref: entry[:ref], reason: :unavailable } }
            )
          end
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
        def emit(memory)
          outbox.record(
            event_type: OUTBOX_EVENT_TYPE,
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
