# frozen_string_literal: true

require "securerandom"
require "time"

module Context
  module Storage
    # The atomic memory write: revision, head, evidence links, search document,
    # the optional global derivative, the optional project override, the
    # idempotency receipt and the outbox event.
    #
    # It owns none of that transaction. The calling service opens it and this
    # object asserts it is inside one, because a storage operation that
    # committed half of a use case would break the only guarantee that matters
    # here: a domain mutation and its outbox row commit together, and `saved`
    # means the whole thing landed (Plan §4.1, §5.1, invariant 2).
    class MemoryWriter
      INDEX_CONFIG_VERSION = "kioku.index.v1"
      OUTBOX_EVENT_TYPE = "memory.revision.committed"

      # What to append to one memory. The derivative reuses it, which is why it
      # names content rather than a request.
      Content = Data.define(
        :memory_key, :destination, :kind, :title, :body, :lifecycle, :authority, :mandatory,
        :applicability, :rationale, :tradeoffs, :valid_from, :valid_until, :task_key,
        :source_anchor, :attempt, :links, :object, :expected_revision
      ) do
        def initialize(destination:, kind:, title:, body:, lifecycle:, authority:, object:,
                       memory_key: nil, mandatory: false, applicability: nil, rationale: nil,
                       tradeoffs: nil, valid_from: nil, valid_until: nil, task_key: nil,
                       source_anchor: nil, attempt: nil, links: {}, expected_revision: nil)
          super
        end
      end

      Written = Data.define(:memory_key, :revision, :head_revision)

      WriteResult = Data.define(
        :memory_key, :revision, :head_revision, :destination, :lifecycle, :authority, :evidence,
        :derivative, :override, :search_document_published, :outbox_event_id, :applicability,
        :receipt_id, :recorded_at
      )

      def initialize(records: Records)
        @records = records
      end

      def call(request:, actor:, authority:, lifecycle:, evidence:, retained_object:,
               derivative_object: nil, now: Time.now.utc)
        records.assert_in_transaction!("memory_writer")
        primary = append(primary_content(request, authority, lifecycle, retained_object), actor: actor,
                                                                                         evidence: evidence, now: now)
        derivative = write_derivative(request, actor, primary, derivative_object, now)
        override = write_override(request, authority, primary, now)
        receipt_id = write_receipt(request, actor, now)
        outbox_id = write_outbox(request, primary, derivative, override, now)
        result(request, primary, derivative, override, receipt_id, outbox_id, authority, lifecycle, evidence, now)
      end

      # Appends one immutable revision, advances the head and republishes the
      # search row for that memory in the same transaction.
      def append(content, actor:, evidence:, now:)
        records.assert_in_transaction!("append_revision")
        key = content.memory_key || new_key
        head = lock_head(key)
        guard_destination!(head, content.destination)
        revision = Domain::Memories::RevisionPolicy.next_revision(
          head_revision: head&.head_revision, expected_revision: content.expected_revision, target_key: key
        )
        insert_revision(key, revision, content, actor, now)
        upsert_head(head, key, content.destination, revision, now)
        link_evidence(key, revision, evidence)
        publish_document(key, revision, content, now)
        Written.new(memory_key: key, revision: revision, head_revision: revision)
      end

      private

      attr_reader :records

      def new_key = SecureRandom.uuid_v7

      # The head row is locked before its revision is computed, so two writers
      # racing on the same memory serialize here instead of both appending
      # revision n+1.
      def lock_head(memory_key)
        records.memory.lock("FOR UPDATE").find_by(memory_key: memory_key)
      end

      # A memory's destination is fixed at creation. An append may not move a
      # project record into the global store or vice versa.
      def guard_destination!(head, destination)
        return if head.nil?
        return if head.store_kind == destination.store_kind && head.project_key == destination.project_key

        raise Errors::AuthorityViolation.new(details: { attempted: "change_memory_destination" })
      end

      def insert_revision(key, revision, content, actor, now)
        records.memory_revision.create!(
          **destination_columns(content.destination), memory_key: key, revision: revision,
          kind: content.kind, title: content.title, body: content.body, lifecycle: content.lifecycle,
          authority: content.authority, mandatory: content.mandatory,
          applicability: content.applicability&.to_wire, rationale: content.rationale,
          tradeoffs: content.tradeoffs, valid_from: content.valid_from || now,
          valid_until: content.valid_until, recorded_at: now, task_key: content.task_key,
          source_anchor: content.source_anchor, attempt: content.attempt, links: content.links,
          **object_columns(content.object), **author_columns(actor)
        )
      end

      def destination_columns(destination)
        {
          store_kind: destination.store_kind, project_key: destination.project_key,
          origin_project_key: destination.origin_project_key, category: destination.category
        }
      end

      # The retained object is already durable on disk when this runs, so the
      # revision row can carry an available handle the moment it commits.
      def object_columns(object)
        {
          object_key: object.object_key, content_hash: object.content_hash,
          hash_algorithm: object.hash_algorithm, byte_length: object.byte_length,
          availability: "available"
        }
      end

      def author_columns(actor)
        {
          author_principal_id: actor.principal_id, author_agent_key: actor.agent_key,
          attribution_state: actor.attribution_state, identity_source: actor.identity_source
        }
      end

      def upsert_head(head, key, destination, revision, now)
        return head.update!(head_revision: revision, updated_at: now) if head

        records.memory.create!(
          **destination_columns(destination), memory_key: key, head_revision: revision,
          created_at: now, updated_at: now
        )
      end

      def link_evidence(key, revision, evidence)
        evidence.accepted.each do |accepted|
          records.memory_evidence.create!(
            memory_key: key, revision: revision, evidence_key: accepted.evidence_key,
            relation: accepted.relation, restricted_source: accepted.restricted_source
          )
        end
      end

      # One current row per memory. An edit makes the previous row ineligible
      # immediately because the row is replaced in the same transaction as the
      # revision that supersedes it.
      def publish_document(key, revision, content, now)
        document = records.memory_search_document.lock.find_or_initialize_by(memory_key: key)
        document.assign_attributes(
          **destination_columns(content.destination), revision: revision, kind: content.kind,
          title: content.title, body: content.body, lifecycle: content.lifecycle,
          authority: content.authority, valid_from: content.valid_from || now,
          valid_until: content.valid_until, recorded_at: now, deleted_at: nil,
          index_config_version: INDEX_CONFIG_VERSION
        )
        document.save!
      end

      def primary_content(request, authority, lifecycle, object)
        Content.new(
          memory_key: request.memory_key, destination: request.destination, kind: request.kind,
          title: request.title, body: request.body, lifecycle: lifecycle, authority: authority,
          mandatory: request.mandatory, applicability: request.applicability,
          rationale: request.rationale, tradeoffs: request.tradeoffs, valid_from: request.valid_from,
          valid_until: request.valid_until, task_key: request.task_key,
          source_anchor: request.source_anchor, attempt: request.attempt, links: request.links,
          object: object, expected_revision: request.envelope.expected_revision
        )
      end

      # The reusable global record. Its provenance link points back at the
      # project revision it was derived from; it carries no project log, path or
      # wholesale source.
      def derivative_content(request, primary, object)
        derivative = request.derivative
        Content.new(
          destination: derivative.destination(origin_project_key: request.destination.project_key),
          kind: request.kind, title: derivative.title, body: derivative.body, lifecycle: "proposed",
          authority: "assistant", applicability: derivative.applicability, rationale: derivative.rationale,
          tradeoffs: derivative.tradeoffs, object: object,
          links: { "derived_from" => ["memory_revision:#{primary.memory_key}@#{primary.revision}"] }
        )
      end

      def write_derivative(request, actor, primary, object, now)
        return nil unless request.publish_derivative?

        written = append(derivative_content(request, primary, object), actor: actor,
                                                                       evidence: empty_evidence, now: now)
        { "global_memory_key" => written.memory_key, "revision" => written.revision }
      end

      # The global side of a split write carries provenance, not the project's
      # evidence links: a global reference to project evidence grants no other
      # project access to it.
      def empty_evidence
        Domain::Evidence::Eligibility::Outcome.new(accepted: [].freeze, rejected: [].freeze)
      end

      def write_override(request, authority, primary, now)
        override = request.override
        return nil if override.nil?

        row = records.project_preference_override.create!(
          override_id: SecureRandom.uuid_v7, project_key: request.destination.project_key,
          target_memory_key: override.target_global_memory_key, target_revision: override.target_revision,
          replacement_body: override.replacement_body, exclusion: override.exclusion,
          reason: override.reason, authority: authority, authority_basis: override.authority_basis,
          valid_from: override.valid_from || now, valid_until: override.valid_until,
          declared_scope: declared_scope(request), created_by_memory_key: primary.memory_key,
          created_by_revision: primary.revision, recorded_at: now
        )
        override_wire(row, request)
      end

      def declared_scope(request)
        scope = request.envelope.scope
        {
          "repository_keys" => [scope.repository_key].compact,
          "worktree_keys" => [scope.worktree_key].compact,
          "task_keys" => [request.task_key || scope.task_key].compact
        }
      end

      def override_wire(row, request)
        {
          "override_id" => row.override_id, "target_global_memory_key" => row.target_memory_key,
          "target_revision" => row.target_revision, "project_key" => request.destination.project_key
        }
      end

      # The receipt commits with the domain rows, so a replay after a lost
      # acknowledgment can only ever find a receipt for work that landed.
      def write_receipt(request, actor, now)
        receipt_id = SecureRandom.uuid_v7
        records.idempotency_receipt.create!(
          receipt_id: receipt_id, actor_principal_id: actor.principal_id,
          idempotency_key: request.envelope.idempotency_key, request_digest: request.envelope.request_digest,
          request_id: request.envelope.request_id, committed_at: now
        )
        receipt_id
      end

      # Domain mutation and outbox commit together. Enqueue-after-commit alone
      # is not an atomic delivery guarantee, so the intent is durable here and a
      # bounded dispatcher schedules the job afterwards.
      def write_outbox(request, primary, derivative, override, now)
        event_id = SecureRandom.uuid_v7
        records.outbox_event.create!(
          event_id: event_id, event_type: OUTBOX_EVENT_TYPE,
          store_kind: request.destination.store_kind, project_key: request.destination.project_key,
          aggregate_key: primary.memory_key, aggregate_revision: primary.revision,
          payload: outbox_payload(primary, derivative, override), state: "pending",
          attempts: 0, available_at: now, created_at: now
        )
        event_id
      end

      def outbox_payload(primary, derivative, override)
        {
          "memory_key" => primary.memory_key, "revision" => primary.revision,
          "derivative_memory_key" => derivative && derivative["global_memory_key"],
          "override_id" => override && override["override_id"]
        }
      end

      def result(request, primary, derivative, override, receipt_id, outbox_id, authority, lifecycle, evidence, now)
        WriteResult.new(
          memory_key: primary.memory_key, revision: primary.revision, head_revision: primary.head_revision,
          destination: request.destination, lifecycle: lifecycle, authority: authority, evidence: evidence,
          derivative: derivative, override: override, search_document_published: true,
          outbox_event_id: outbox_id, applicability: request.applicability, receipt_id: receipt_id,
          recorded_at: now
        )
      end
    end
  end
end
