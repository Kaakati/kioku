# frozen_string_literal: true

module Context
  module Services
    module Memories
      class Remember
        # The canonical commit receipt of the frozen contract:
        # {receipt_id, idempotency_key, request_digest, committed_at, replayed}.
        #
        # `replayed` describes this call rather than the stored row — a receipt
        # that is found is by definition a replay — so it is not a column.
        class Receipt
          attr_reader :receipt_id, :idempotency_key, :request_digest, :committed_at

          def initialize(record:, replayed:)
            @receipt_id = record.receipt_id
            @idempotency_key = record.idempotency_key
            @request_digest = record.request_digest
            @committed_at = record.committed_at
            @replayed = replayed
            freeze
          end

          def replayed?
            @replayed
          end

          def to_h
            {
              receipt_id: receipt_id,
              idempotency_key: idempotency_key,
              request_digest: request_digest,
              committed_at: committed_at,
              replayed: replayed?
            }
          end
        end
      end
    end
  end
end
