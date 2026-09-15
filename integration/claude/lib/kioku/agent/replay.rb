# frozen_string_literal: true

module Kioku
  module Agent
    # Drains the durable host spool to the core.
    #
    # An entry is retired only against a canonical receipt naming it. A lost
    # acknowledgment therefore replays the entry, which the core deduplicates by
    # idempotency key; a missing or unrecognised receipt leaves the entry
    # pending. Nothing here marks an entry saved on its own authority.
    class Replay
      BATCH_SIZE = 50

      def initialize(spool:, bridge:, logger:)
        @spool = spool
        @bridge = bridge
        @logger = logger
      end

      def run_once
        batch = @spool.pending.first(BATCH_SIZE)
        return { "replayed" => 0, "acknowledged" => 0 } if batch.empty?

        response = @bridge.replay(entries: batch.map(&:record))
        acknowledged = retire(response)
        { "replayed" => batch.length, "acknowledged" => acknowledged }
      rescue Kioku::TransportUnavailable => e
        @logger.debug("replay deferred", reason: e.message)
        { "replayed" => 0, "acknowledged" => 0, "deferred" => true }
      end

      private

      def retire(response)
        receipts = response.dig("data", "receipts")
        return 0 unless receipts.is_a?(Array)

        receipts.count { |receipt| acknowledge(receipt) }
      end

      def acknowledge(receipt)
        entry_id = receipt["spool_entry_id"]
        return false if entry_id.nil? || receipt["committed_at"].nil?

        @spool.acknowledge(entry_id, receipt: receipt)
      end
    end
  end
end
