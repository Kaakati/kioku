# frozen_string_literal: true

require "time"

module Context
  module Services
    module Memories
      # Commits one evidence-linked durable memory revision.
      #
      # This is the worked example of Plan §4.1 and the ordering of §7.1, and
      # the order is the contract:
      #
      #   1. validate the request contract and the remaining deadline
      #   2. derive authority from the transport, never from the payload
      #   3. authorize the destination and the scope it was requested under
      #   4. replay a prior receipt for the same idempotency key and digest
      #   5. resolve and check evidence eligibility
      #   6. make the retained object bytes durable — before the transaction
      #   7. inside one transaction: lock the head, check the expected revision,
      #      append the revision, advance the head, publish the search row,
      #      write the idempotency receipt and the outbox event
      #   8. only after that transaction commits, report saved
      #
      # Nothing here turns a failed save into a successful result. An
      # unexpected exception propagates, a conflict writes nothing, and there
      # is no path that reports `saved` for work that did not commit.
      class Remember
        MAX_TRANSACTION_ATTEMPTS = 3

        Replay = Data.define(:receipt)
        private_constant :Replay

        def initialize(object_store: Storage::ObjectStore.new,
                       memory_writer: Storage::MemoryWriter.new,
                       eligibility: Domain::Evidence::Eligibility.new,
                       authorization: Queries::ScopeAuthorization.new,
                       evidence_refs: Queries::Evidence::ResolveRefs.new,
                       receipts: Queries::Idempotency::FindReceipt.new,
                       generations: Queries::Generations.new,
                       records: Storage::Records)
          @object_store = object_store
          @memory_writer = memory_writer
          @eligibility = eligibility
          @authorization = authorization
          @evidence_refs = evidence_refs
          @receipts = receipts
          @generations = generations
          @records = records
        end

        def call(payload:, actor:, host_link_state: "disconnected", now: Time.now.utc)
          request = Contracts::MemoryWrite.parse(payload, started_at: now)
          request.envelope.deadline.ensure!(now)
          authority = authority_for(actor, request)
          lifecycle = Domain::Memories::AuthorityPolicy.resolve_lifecycle(
            authority: authority, destination: request.destination, requested: request.lifecycle
          )
          authorized = authorization.call(actor: actor, scope: request.envelope.scope, destination: request.destination)
          prior = find_receipt(request, actor)
          return replayed(request, prior, actor, host_link_state, now) if prior

          evidence = eligible_evidence(request, authorized)
          authorize_override!(request, actor, authority)
          objects = stage_objects(request, now)
          outcome = commit(request, actor, authority, lifecycle, evidence, objects, now)
          return replayed(request, outcome.receipt, actor, host_link_state, now) if outcome.is_a?(Replay)

          saved(request, outcome, actor, evidence, host_link_state, now)
        end

        private

        attr_reader :object_store, :memory_writer, :eligibility, :authorization,
                    :evidence_refs, :receipts, :generations, :records

        def authority_for(actor, request)
          authority = Domain::Memories::AuthorityPolicy.derive(actor: actor)
          Domain::Memories::AuthorityPolicy.check_mandatory!(mandatory: request.mandatory, authority: authority)
          authority
        end

        def find_receipt(request, actor)
          receipts.call(principal_id: actor.principal_id,
                        idempotency_key: request.envelope.idempotency_key,
                        request_digest: request.envelope.request_digest)
        end

        def eligible_evidence(request, authorized)
          candidates = evidence_refs.call(refs: request.evidence, authorized_scope: authorized)
          outcome = eligibility.call(candidates: candidates, destination: request.destination)
          return outcome if outcome.eligible?

          raise Errors::EvidenceRequired.new(
            details: { evidence_rejected: Serialization::EvidenceReport.rejected_wire(outcome) }
          )
        end

        # An override names an exact global revision. Reading it is its own
        # boundary, so the global grant is checked here rather than inherited
        # from the project write that carries it.
        def authorize_override!(request, actor, authority)
          override = request.override
          return if override.nil?

          authorization.call(actor: actor, scope: Contracts::Scope.new(store: "global"))
          target = records.memory_revision.find_by(memory_key: override.target_global_memory_key,
                                                   revision: override.target_revision, store_kind: "global")
          raise Errors::HandleUnresolved.new(details: { kind: "global_record_revision" }) if target.nil?

          Domain::Memories::AuthorityPolicy.check_override!(
            actor_authority: authority, target_authority: target.authority, target_mandatory: target.mandatory
          )
        end

        # Step 6. Outside the transaction on purpose: filesystem work does not
        # belong inside a write transaction, and the bytes must already be
        # durable when the revision row that exposes them commits.
        def stage_objects(request, now)
          {
            retained: object_store.put(bytes: retained_payload(request, now)),
            derivative: request.publish_derivative? ? object_store.put(bytes: derivative_payload(request, now)) : nil
          }
        end

        def retained_payload(request, now)
          Contracts::Canonical.encode(
            "schema_version" => Context::CONTRACT_ID, "kind" => request.kind, "title" => request.title,
            "body" => request.body, "rationale" => request.rationale, "tradeoffs" => request.tradeoffs,
            "attempt" => request.attempt, "source_anchor" => request.source_anchor, "recorded_at" => now
          )
        end

        def derivative_payload(request, now)
          derivative = request.derivative
          Contracts::Canonical.encode(
            "schema_version" => Context::CONTRACT_ID, "category" => derivative.category,
            "title" => derivative.title, "body" => derivative.body, "rationale" => derivative.rationale,
            "tradeoffs" => derivative.tradeoffs, "permitted_excerpt" => derivative.permitted_excerpt,
            "applicability" => derivative.applicability.to_wire, "recorded_at" => now
          )
        end

        # Step 7. The service owns this transaction; the writer participates in
        # it. Deadlock and serialization failures are retried within the
        # caller's remaining deadline, which is safe because the idempotency
        # receipt commits with the rest.
        def commit(request, actor, authority, lifecycle, evidence, objects, now)
          attempts = 0
          begin
            attempts += 1
            records.base.transaction do
              memory_writer.call(request: request, actor: actor, authority: authority, lifecycle: lifecycle,
                                 evidence: evidence, retained_object: objects[:retained],
                                 derivative_object: objects[:derivative], now: now)
            end
          rescue ActiveRecord::Deadlocked, ActiveRecord::SerializationFailure
            request.envelope.deadline.ensure!
            retry if attempts < MAX_TRANSACTION_ATTEMPTS
            raise
          rescue ActiveRecord::RecordNotUnique
            raced(request, actor)
          end
        end

        # Another writer got there first. If it was this same request, its
        # receipt is now readable and we replay it; otherwise the head moved
        # under us and the stale writer fails without writing anything.
        def raced(request, actor)
          prior = find_receipt(request, actor)
          return Replay.new(receipt: prior) if prior

          raise Errors::RevisionConflict.new(details: { target_key: request.memory_key })
        end

        # Step 8. MemorySave.committed is the only constructor, and it takes the
        # commit instant, so `saved` cannot be reported before this point.
        def saved(request, written, actor, evidence, host_link_state, now)
          save = Serialization::MemorySave.committed(written, committed_at: written.recorded_at)
          result(request, actor, host_link_state, now,
                 data: save.to_wire,
                 coverage: Serialization::EvidenceReport.coverage(evidence, requested: request.evidence),
                 receipt: commit_receipt(request, written))
        end

        def replayed(request, receipt, actor, host_link_state, now)
          result(request, actor, host_link_state, now,
                 data: receipt.payload,
                 coverage: Serialization::Coverage.complete(
                   declared_input_set: { "requested_evidence" => request.evidence.map { |ref| Serialization::EvidenceReport.handle_wire(ref.ref) } },
                   considered: request.evidence.length, returned: request.evidence.length
                 ),
                 receipt: receipt.to_wire(replayed: true))
        end

        def commit_receipt(request, written)
          {
            "receipt_id" => written.receipt_id, "idempotency_key" => request.envelope.idempotency_key,
            "request_digest" => request.envelope.request_digest,
            "committed_at" => written.recorded_at.utc.iso8601(3), "replayed" => false
          }
        end

        def result(request, actor, host_link_state, now, data:, coverage:, receipt:)
          Serialization::Result.success(
            request_id: request.envelope.request_id, deadline: request.envelope.deadline,
            generation_vector: generations.call(installation_id: actor.installation_id,
                                                project_key: request.destination.project_key,
                                                host_link_state: host_link_state, now: now),
            coverage: coverage, data: data, receipt: receipt,
            token_budget: request.envelope.token_budget, returned: 1, now: now
          )
        end
      end
    end
  end
end
