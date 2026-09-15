# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"

require_relative "../errors"
require_relative "spool/store"

module Kioku
  module Agent
    # The durable bounded spool [plan §3; §7.1 steps 2 and 6].
    #
    # "queued means durable host enqueue only; saved means canonical commit. A timeout or
    # missing acknowledgment is never reported as a save" [contracts: errors kioku.queued;
    # plan invariant 2]. An entry stays pending until a canonical receipt acknowledges it,
    # and the spool refuses a new capture rather than evicting an unacknowledged one:
    # "durable unacknowledged records must not be silently discarded to make room"
    # [plan §7.1].
    class Spool
      Entry = Struct.new(:spool_entry_id, :envelope, keyword_init: true)

      Receipt = Struct.new(:status, :spool_entry_id, :producer_key, :producer_epoch,
                           :producer_sequence, :canonical_receipt, :replayed, keyword_init: true) do
        def saved?
          !canonical_receipt.nil?
        end

        def replayed?
          replayed
        end
      end

      CANONICAL_RECEIPT_FIELDS = %w[receipt_id idempotency_key request_digest committed_at].freeze

      def initialize(dir:, max_bytes: 64 * 1024 * 1024)
        @store = Store.new(dir: dir)
        @max_bytes = max_bytes
      end

      def enqueue(envelope:, idempotency_key:, request_digest:)
        prior = @store.receipt_for(idempotency_key)
        return replay(prior, request_digest) if replayable?(prior)

        record = build_entry(envelope, idempotency_key, request_digest)
        enforce_bound(record.fetch("byte_length"))
        @store.append(entry: record, receipt: receipt_record(record))
        receipt_for_record(record, replayed: false)
      end

      # "The agent acknowledges/retires spool entries only after the canonical receipt"
      # [plan §7.1 step 6].
      def acknowledge(spool_entry_id:, canonical_receipt:)
        require_canonical_receipt(canonical_receipt)
        record = @store.entries.find { |entry| entry.fetch("spool_entry_id") == spool_entry_id }
        handle_unresolved!(spool_entry_id) if record.nil?

        @store.save_receipt(receipt_record(record).merge("canonical_receipt" => canonical_receipt))
        @store.retire(spool_entry_id)
        receipt_for_record(record, replayed: false, canonical_receipt: canonical_receipt)
      end

      def pending
        @store.entries.map do |record|
          Entry.new(spool_entry_id: record.fetch("spool_entry_id"), envelope: record.fetch("envelope"))
        end
      end

      def pending_count
        @store.entries.size
      end

      # Entries the spool acknowledged as queued that did not reopen. Every capture
      # the caller was told was durable is either here or in `pending`; none is
      # dropped [contracts: errors kioku.quota_exhausted; plan §9].
      def losses
        @store.losses
      end

      def receipt_for(idempotency_key:)
        record = @store.receipt_for(idempotency_key)
        return nil if record.nil?

        receipt_for_record(record, replayed: true, canonical_receipt: record["canonical_receipt"])
      end

      private

      def build_entry(envelope, idempotency_key, request_digest)
        sequence = @store.next_sequence
        record = {
          "spool_entry_id" => "spool-#{@store.producer_epoch}-#{sequence}-#{SecureRandom.hex(4)}",
          "producer_key" => @store.producer_key,
          "producer_epoch" => @store.producer_epoch,
          "producer_sequence" => sequence,
          "idempotency_key" => idempotency_key,
          "request_digest" => request_digest,
          "enqueued_at" => Time.now.utc.iso8601,
          "envelope" => envelope
        }
        record.merge("byte_length" => JSON.generate(record).bytesize)
      end

      def receipt_record(record)
        record.slice("spool_entry_id", "producer_key", "producer_epoch", "producer_sequence",
                     "idempotency_key", "request_digest")
              .merge("canonical_receipt" => nil)
      end

      def receipt_for_record(record, replayed:, canonical_receipt: nil)
        Receipt.new(status: canonical_receipt.nil? ? "queued" : "success",
                    spool_entry_id: record.fetch("spool_entry_id"),
                    producer_key: record.fetch("producer_key"),
                    producer_epoch: record.fetch("producer_epoch"),
                    producer_sequence: record.fetch("producer_sequence"),
                    canonical_receipt: canonical_receipt, replayed: replayed)
      end

      # A receipt whose canonical receipt has arrived answers a replay from the
      # canonical commit, so its capture is rightly gone. A receipt that has NOT
      # been canonically acknowledged answers only for a capture still on disk:
      # once the entry is lost, replaying from that receipt would report a capture
      # that no longer exists as durably enqueued, which is the one thing a
      # durability claim may never do. The capture is accepted again instead.
      def replayable?(prior)
        return false if prior.nil?
        return true unless prior["canonical_receipt"].nil?

        @store.pending?(prior.fetch("spool_entry_id"))
      end

      # "Repeating the same idempotency key and payload returns the prior receipt; a
      # different payload conflicts" [plan §7.1].
      def replay(prior, request_digest)
        conflict!(prior) unless prior.fetch("request_digest") == request_digest

        receipt_for_record(prior, replayed: true, canonical_receipt: prior["canonical_receipt"])
      end

      def conflict!(prior)
        raise Kioku::Error.new("kioku.idempotency_conflict",
                               message: "the idempotency key was reused with a different request digest",
                               details: { "prior_receipt_id" => prior.fetch("spool_entry_id") })
      end

      # "Disk/spool exhaustion produces visible failure and loss accounting; it never
      # produces a false durable acknowledgment" [contracts: errors kioku.quota_exhausted].
      def enforce_bound(byte_length)
        observed = @store.pending_bytes + byte_length
        return if observed <= @max_bytes

        raise Kioku::Error.new("kioku.quota_exhausted",
                               message: "the durable spool is full and will not evict unacknowledged entries",
                               details: { "quota_kind" => "spool_disk", "limit" => @max_bytes,
                                          "observed" => observed })
      end

      def require_canonical_receipt(canonical_receipt)
        return if canonical_receipt.is_a?(Hash) &&
                  CANONICAL_RECEIPT_FIELDS.all? { |field| present?(canonical_receipt[field]) }

        raise Kioku::Error.new("kioku.invalid_request",
                               message: "an entry is retired only against a canonical commit receipt",
                               details: { "required" => CANONICAL_RECEIPT_FIELDS })
      end

      def present?(value)
        !value.nil? && !(value.is_a?(String) && value.strip.empty?)
      end

      def handle_unresolved!(spool_entry_id)
        raise Kioku::Error.new("kioku.handle_unresolved",
                               message: "no pending spool entry carries that identifier",
                               details: { "spool_entry_id" => spool_entry_id })
      end
    end
  end
end
