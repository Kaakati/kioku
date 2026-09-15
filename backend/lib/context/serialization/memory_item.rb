# frozen_string_literal: true

module Context
  module Serialization
    # One memory or global engineering record as it appears in a read result.
    #
    # Shared by the HTTP/UI surface and the MCP adapter so both describe the
    # same record the same way. Ownership is always explicit: a global record
    # names its origin project as provenance and its owner project as nil, and
    # a snippet is always marked a preview rather than an evidence handle.
    class MemoryItem < Data.define(
      :handle, :subject_kind, :store_kind, :owner, :category, :memory_kind,
      :title, :snippet, :revision, :head_revision, :labels, :evidence_handles, :fetch_handle
    )
      def initialize(handle:, subject_kind:, store_kind:, owner:, title:, revision:, head_revision:,
                     labels:, category: nil, memory_kind: nil, snippet: nil, evidence_handles: [],
                     fetch_handle: nil)
        super
      end

      # row is an Active Record object or any struct exposing the same readers.
      def self.from_row(row, coverage:, relevance: nil, snippet: nil)
        store_kind = row.store_kind
        new(
          handle: "memory_key:#{row.memory_key}",
          subject_kind: store_kind == "global" ? "global_record" : "memory",
          store_kind: store_kind,
          owner: { "project_key" => row.project_key, "origin_project_key" => row.try(:origin_project_key) },
          category: row.try(:category),
          memory_kind: row.kind,
          title: row.title,
          snippet: snippet && preview(snippet),
          revision: row.revision,
          head_revision: row.try(:head_revision) || row.revision,
          labels: labels_for(row, coverage, relevance),
          evidence_handles: Array(row.try(:evidence_handles)),
          fetch_handle: "memory_revision:#{row.memory_key}@#{row.revision}"
        )
      end

      # A snippet is a bounded preview produced by the search index. It is never
      # an exact evidence handle, and callers are told so in the payload itself.
      def self.preview(text)
        { "text" => text, "is_preview" => true, "not_an_evidence_handle" => true }.freeze
      end

      def self.labels_for(row, coverage, relevance)
        Labels.new(
          authority: row.authority,
          lifecycle: row.lifecycle,
          availability: row.try(:availability) || "available",
          applicability: row.try(:applicability) || "unknown",
          coverage: coverage,
          claim_support: row.try(:claim_support) || Labels::UNASSESSED,
          dispute: row.try(:dispute) || Labels::NO_DISPUTE,
          override_status: row.try(:override_status) || "none",
          relevance: relevance
        ).validate!
      end

      private_class_method :preview, :labels_for

      def to_wire
        {
          "handle" => handle, "subject_kind" => subject_kind, "store_kind" => store_kind,
          "owner" => owner, "category" => category, "memory_kind" => memory_kind,
          "title" => title, "snippet" => snippet, "revision" => revision,
          "head_revision" => head_revision, "evidence_handles" => evidence_handles,
          "fetch_handle" => fetch_handle
        }.merge(labels.to_wire)
      end
    end
  end
end
