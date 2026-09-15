# frozen_string_literal: true

module Context
  module Services
    module Memories
      class Remember
        # The small operation-specific result plan 4.1 asks a service to return.
        #
        # Invariant 2: `saved` means canonical commit and nothing else. A refusal
        # carries the frozen wire code and its details so the HTTP and MCP
        # boundaries map one table, not two.
        class Result
          attr_reader :status, :memory_key, :revision, :head_revision, :store_kind,
                      :project_key, :category, :lifecycle, :authority, :receipt,
                      :outbox_event_id, :applicability, :evidence_accepted,
                      :evidence_rejected, :error_code, :error_details

          def self.committed(memory:, revision:, request:, receipt:, outbox_event_id:,
                             evidence_accepted:, evidence_rejected:)
            new(
              status: :success, memory_key: memory.memory_key, revision: revision,
              head_revision: memory.current_revision, store_kind: memory.store_kind,
              project_key: memory.project_key, category: memory.category,
              lifecycle: request.effective_lifecycle, authority: request.authority,
              receipt: receipt, outbox_event_id: outbox_event_id,
              applicability: request.applicability,
              evidence_accepted: evidence_accepted, evidence_rejected: evidence_rejected
            )
          end

          def self.replayed(record:, head_revision:, receipt:)
            new(status: :success, memory_key: record.memory_key, revision: record.revision,
                head_revision: head_revision, receipt: receipt)
          end

          def self.refused(error)
            new(status: error.wire_status, error_code: error.wire_code,
                error_details: error.details)
          end

          def initialize(status:, memory_key: nil, revision: nil, head_revision: nil,
                         store_kind: nil, project_key: nil, category: nil, lifecycle: nil,
                         authority: nil, receipt: nil, outbox_event_id: nil,
                         applicability: nil, evidence_accepted: [], evidence_rejected: [],
                         error_code: nil, error_details: {})
            @status = status
            @memory_key = memory_key
            @revision = revision
            @head_revision = head_revision
            @store_kind = store_kind
            @project_key = project_key
            @category = category
            @lifecycle = lifecycle
            @authority = authority
            @receipt = receipt
            @outbox_event_id = outbox_event_id
            @applicability = applicability
            @evidence_accepted = evidence_accepted
            @evidence_rejected = evidence_rejected
            @error_code = error_code
            @error_details = error_details
            freeze
          end

          def saved?
            status == :success
          end
        end
      end
    end
  end
end
