# frozen_string_literal: true

module Context
  module Queries
    module Idempotency
      # Looks up the receipt for an actor-scoped idempotency key.
      #
      # Same key and same request digest returns the prior receipt verbatim, so
      # a retry after a lost acknowledgment replays rather than writing twice.
      # Same key and a different digest is kioku.idempotency_conflict and writes
      # nothing: a caller that changed its payload must change its key.
      class FindReceipt
        Receipt = Data.define(:receipt_id, :idempotency_key, :request_digest, :committed_at, :payload) do
          def to_wire(replayed: true)
            {
              "receipt_id" => receipt_id, "idempotency_key" => idempotency_key,
              "request_digest" => request_digest,
              "committed_at" => committed_at&.utc&.iso8601(3), "replayed" => replayed
            }
          end
        end

        def initialize(records: Storage::Records)
          @records = records
        end

        def call(principal_id:, idempotency_key:, request_digest:)
          row = @records.idempotency_receipt.find_by(
            actor_principal_id: principal_id, idempotency_key: idempotency_key
          )
          return nil if row.nil?

          conflict!(row, request_digest) unless row.request_digest == request_digest
          Receipt.new(receipt_id: row.receipt_id, idempotency_key: row.idempotency_key,
                      request_digest: row.request_digest, committed_at: row.committed_at,
                      payload: row.response_payload)
        end

        private

        def conflict!(row, supplied)
          raise Errors::IdempotencyConflict.new(
            details: { prior_receipt_id: row.receipt_id, prior_request_digest: row.request_digest,
                       supplied_request_digest: supplied }
          )
        end
      end
    end
  end
end
