# frozen_string_literal: true

module Context
  module Queries
    module Evidence
      # Turns requested evidence handles into the plain facts the eligibility
      # policy needs: whether they resolved, who owns them, whether they are
      # deleted, whether their bytes are actually there.
      #
      # A raw object key or content hash is never accepted as permission. An
      # object handle resolves only through an evidence row the caller's scope
      # can see, and a handle that does not exist is reported exactly like one
      # in a scope the caller cannot see (Plan §5.3).
      class ResolveRefs
        EVIDENCE_KINDS = %w[evidence evidence_key].freeze
        OBJECT_KINDS = %w[object object_key].freeze
        EVENT_KINDS = %w[event_key].freeze

        def initialize(records: Storage::Records, object_store: Storage::ObjectStore.new)
          @records = records
          @object_store = object_store
        end

        def call(refs:, authorized_scope:)
          refs.map { |ref| resolve(ref, authorized_scope) }
        end

        private

        attr_reader :records, :object_store

        def resolve(ref, authorized_scope)
          row = lookup(ref.ref, authorized_scope)
          return unresolved(ref) if row.nil?

          Domain::Evidence::Candidate.new(
            ref: ref.ref, relation: ref.relation, resolved: true, evidence_key: row.evidence_key,
            store_kind: row.store_kind, project_key: row.project_key,
            availability: row.availability, deleted: !row.deleted_at.nil?,
            deletion_epoch: row.deletion_epoch, source_anchor: row.source_anchor,
            object_backed: !row.object_key.nil?, object_available: object_available?(row)
          )
        end

        def unresolved(ref)
          Domain::Evidence::Candidate.new(ref: ref.ref, relation: ref.relation, resolved: false)
        end

        def lookup(handle, authorized_scope)
          visible = in_scope(records.evidence.all, authorized_scope)
          case handle.kind
          when *EVIDENCE_KINDS then visible.find_by(evidence_key: handle.key)
          when *OBJECT_KINDS then visible.find_by(object_key: handle.key)
          when *EVENT_KINDS then visible.find_by(origin_event_key: handle.key)
          end
        end

        # Installation-owned evidence has no project. Everything else must
        # belong to a project the caller was granted.
        def in_scope(relation, authorized_scope)
          table = relation.klass.arel_table
          relation.where(table[:project_key].eq(nil).or(table[:project_key].in(authorized_scope.project_keys)))
        end

        # Metadata saying "available" is not proof that the bytes survived.
        # Object-backed evidence is only available when the object directory
        # actually holds the content.
        def object_available?(row)
          return false if row.object_key.nil?

          object = records.source_object.find_by(object_key: row.object_key)
          return false if object.nil? || object.availability != "available"

          object_store.available?(content_hash: object.content_hash)
        end
      end
    end
  end
end
