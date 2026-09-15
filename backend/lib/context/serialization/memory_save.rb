# frozen_string_literal: true

require "time"

module Context
  module Serialization
    # The context_remember data payload.
    #
    # `saved` is not a field anyone can set: it is derived from committed_at,
    # which only a completed canonical transaction supplies. There is therefore
    # no construction path that reports a save for a write that did not commit
    # (Plan invariant 2).
    class MemorySave < Data.define(
      :memory_key, :revision, :head_revision, :destination, :lifecycle, :authority,
      :committed_at, :evidence, :derivative, :override, :search_document_published,
      :outbox_event_id, :applicability
    )
      def initialize(memory_key:, revision:, head_revision:, destination:, lifecycle:, authority:,
                     committed_at:, evidence:, search_document_published:, outbox_event_id:,
                     derivative: nil, override: nil, applicability: nil)
        super
      end

      # The only constructor. It takes the commit instant, so it cannot be
      # built before the transaction that produced it has committed.
      def self.committed(write_result, committed_at: Time.now.utc)
        new(
          memory_key: write_result.memory_key, revision: write_result.revision,
          head_revision: write_result.head_revision, destination: write_result.destination,
          lifecycle: write_result.lifecycle, authority: write_result.authority,
          committed_at: committed_at.utc, evidence: write_result.evidence,
          derivative: write_result.derivative, override: write_result.override,
          search_document_published: write_result.search_document_published,
          outbox_event_id: write_result.outbox_event_id,
          applicability: write_result.applicability
        )
      end

      def saved = !committed_at.nil?

      def to_wire
        {
          "memory_key" => memory_key, "revision" => revision, "head_revision" => head_revision,
          "store_kind" => destination.store_kind, "owner" => owner_wire,
          "category" => destination.category, "lifecycle" => lifecycle, "authority" => authority,
          "saved" => saved,
          "evidence_accepted" => EvidenceReport.accepted_wire(evidence),
          "evidence_rejected" => EvidenceReport.rejected_wire(evidence),
          "derivative" => derivative, "override" => override,
          "search_document_published" => search_document_published,
          "outbox_event_id" => outbox_event_id,
          "applicability" => applicability&.to_wire,
          # A save records a conclusion; it never establishes support.
          "claim_support" => "unassessed"
        }
      end

      def owner_wire
        { "project_key" => destination.project_key, "origin_project_key" => destination.origin_project_key }
      end
      private :owner_wire
    end
  end
end
