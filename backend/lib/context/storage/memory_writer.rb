# frozen_string_literal: true

module Context
  module Storage
    # The canonical write of one memory revision: the capture event it is
    # attributed to, the head, the immutable revision, its evidence links, the
    # derived search projection and the idempotency receipt (plan 4.1's storage
    # row, "Append revision + head + receipt + outbox atomically").
    #
    # It participates in the caller's transaction and never opens one of its
    # own. Remember owns the transaction boundary for the use case, because half
    # a commit is not a save (plan 4.1, invariant 2).
    class MemoryWriter
      SOURCE_ANCHOR = {
        "schema_version" => "kioku.source_anchor.v1",
        "repository_key" => nil,
        "path" => nil
      }.freeze

      EVIDENCE_KIND = "retained_object"
      CAPTURE_EVENT_TYPE = "memory_remembered"

      # The host spool owns producer epochs and sequences; a capture that
      # originates at the core has no spool epoch to replay. request_id is unique
      # per attempt (frozen contract), so it names this producer's epoch. Replay
      # safety for a core capture comes from the idempotency receipt, not from
      # this key.
      PRODUCER_KEY = "core.remember"

      # Taken under FOR UPDATE so two writers cannot both read the same head and
      # both believe their expected_revision is current.
      def locked_head(memory_key)
        Memory.lock.find_by(memory_key: memory_key)
      end

      # Appends to `head`, or creates the memory when it is nil. Returns the head
      # the revision was written against.
      def append(request:, head:, evidence:)
        memory = upsert_head(request, head)
        event = record_capture_event(request)
        write_revision(request, memory, event)
        link_evidence(memory, event, evidence)
        publish_search_document(request, memory)
        memory
      end

      def write_receipt(request:, memory:)
        actor = request.actor
        IdempotencyReceipt.create!(
          receipt_id: "receipt-#{SecureRandom.uuid_v7}",
          idempotency_key: request.envelope.idempotency_key,
          installation_key: actor.installation_key,
          actor_principal_id: actor.principal_id,
          # E1. The digest the core COMPUTED over the received content, never the value
          # the caller asserted. The replay comparison reads this column, so storing the
          # assertion would leave a caller deciding its own durability claim.
          request_digest: request.computed_digest,
          memory_key: memory.memory_key,
          revision: memory.current_revision,
          committed_at: Time.current
        )
      end

      # The frozen contract scopes an idempotency key to its actor, so the lookup
      # is scoped too. By key alone this hands one writer another writer's
      # receipt: a save that caller never made, or a conflict quoting a receipt
      # id and request digest from a scope it cannot see.
      def receipt_for(actor:, idempotency_key:)
        IdempotencyReceipt.find_by(
          installation_key: actor.installation_key,
          actor_principal_id: actor.principal_id,
          idempotency_key: idempotency_key
        )
      end

      def head_revision_of(memory_key)
        Memory.where(memory_key: memory_key).pick(:current_revision)
      end

      private

      def upsert_head(request, head)
        return head.tap { |memory| memory.update!(current_revision: memory.current_revision + 1) } if head

        Memory.create!(
          memory_key: "memory-#{SecureRandom.uuid_v7}",
          scope_key: scope_key_for(request),
          store_kind: request.store_kind.to_s,
          project_key: request.owned_project_key,
          origin_project_key: request.origin_project_key,
          category: request.category&.to_s,
          current_revision: 1
        )
      end

      def record_capture_event(request)
        actor = request.actor
        Event.create!(
          event_key: "event-#{SecureRandom.uuid_v7}",
          installation_key: actor.installation_key,
          store_kind: request.store_kind.to_s,
          project_key: request.owned_project_key,
          producer_key: PRODUCER_KEY,
          producer_epoch: request.envelope.request_id,
          producer_sequence: 0,
          agent_key: actor.agent_key,
          # The actor's own claim, never one derived from agent_key nullability.
          # "There is no agent to join to" (not_applicable) is a stronger
          # statement than "the join was not established" (unresolved), and only
          # the actor knows which is true; asserting the stronger one from an
          # absent column is invariant 9's false independent confirmation
          # (research §8: attribution "can remain null until resolved").
          attribution_state: actor.attribution_state.to_s,
          # How identity was established is a recorded fact, in the one
          # vocabulary agents.identity_source declares (frozen contract,
          # transport_and_actor).
          identity_source: actor.identity_source.to_s,
          event_type: CAPTURE_EVENT_TYPE,
          origin_role: actor.origin_role.to_s,
          observed_at: Time.current,
          recorded_at: Time.current
        )
      end

      def write_revision(request, memory, event)
        MemoryRevision.create!(
          memory_key: memory.memory_key,
          revision: memory.current_revision,
          kind: request.kind.to_s,
          title: request.title,
          body: request.body,
          lifecycle: request.effective_lifecycle.to_s,
          authority: request.authority.to_s,
          author_event_key: event.event_key,
          author_agent_key: request.actor.agent_key,
          valid_from: Time.current,
          recorded_at: Time.current
        )
      end

      def link_evidence(memory, event, accepted)
        accepted.each do |entry|
          evidence = ::Evidence.create!(
            evidence_key: "evidence-#{SecureRandom.uuid_v7}",
            scope_key: memory.scope_key,
            evidence_kind: EVIDENCE_KIND,
            origin_event_key: event.event_key,
            object_key: entry[:ref][:object_key],
            source_anchor: SOURCE_ANCHOR
          )
          MemoryEvidence.create!(memory_key: memory.memory_key, revision: memory.current_revision,
                                 evidence_key: evidence.evidence_key,
                                 relation: entry[:relation].to_s)
        end
      end

      # The derived lexical projection is published in the same transaction as
      # the canonical change it projects (plan 5.4), and there is one current
      # document per memory, so an append replaces it rather than adding one.
      #
      # The lifecycle travels with it: the retrieval gate runs on this table, so
      # a projection that does not carry the revision's lifecycle leaves a
      # retracted or superseded head fully retrievable by BM25.
      def publish_search_document(request, memory)
        document = MemorySearchDocument.find_or_initialize_by(memory_key: memory.memory_key)
        document.update!(revision: memory.current_revision, store_kind: memory.store_kind,
                         project_key: memory.project_key, title: request.title,
                         body: request.body, lifecycle: request.effective_lifecycle.to_s)
      end

      # A project scope must already exist: registration is an operator/UI setup
      # API, not something a memory write performs (plan 6.2). The installation's
      # global scope has no registration step, so it is the one anchor this write
      # may create.
      def scope_key_for(request)
        installation_key = request.actor.installation_key
        return global_scope_key(installation_key) if request.global?

        scope = ::Scope.find_by(installation_key: installation_key, scope_kind: "project",
                                project_key: request.project_key)
        return scope.scope_key if scope

        raise Errors::ProjectBindingUnresolved.new(
          "the project is not registered for this installation",
          details: { setup_required: true }
        )
      end

      def global_scope_key(installation_key)
        ::Scope.create_with(scope_key: "scope-#{SecureRandom.uuid_v7}")
               .find_or_create_by!(installation_key: installation_key, scope_kind: "global",
                                   subject_key: installation_key)
               .scope_key
      end
    end
  end
end
