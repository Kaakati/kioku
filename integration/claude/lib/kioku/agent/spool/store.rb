# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

module Kioku
  module Agent
    class Spool
      # The durable file layout behind the bounded spool [plan §3 "Durable bounded spool"].
      #
      # Entries and receipts are separate: an entry holds the capture that has not reached
      # canonical commit and is deleted when it is acknowledged, while its receipt survives
      # so a replay after a lost acknowledgment can hand back the canonical receipt instead
      # of re-enqueuing the capture. Only entry bytes count against the spool bound, so
      # acknowledging entries reclaims space and retained receipts never wedge the spool.
      class Store
        PRODUCER_FILE = "producer.json"
        ENTRIES_DIR = "entries"
        RECEIPTS_DIR = "receipts"

        attr_reader :producer_key, :producer_epoch

        def initialize(dir:)
          @dir = dir
          FileUtils.mkdir_p([entries_dir, receipts_dir])
          load_producer
          @entries = load_entries
          @receipts = load_receipts
        end

        def entries
          @entries.values
        end

        def pending_bytes
          @entries.values.sum { |record| record.fetch("byte_length") }
        end

        def receipt_for(idempotency_key)
          @receipts[idempotency_key]
        end

        def next_sequence
          @sequence += 1
          write_producer
          @sequence
        end

        def append(entry:, receipt:)
          write_json(entry_path(entry.fetch("spool_entry_id")), entry)
          @entries[entry.fetch("spool_entry_id")] = entry
          save_receipt(receipt)
        end

        def save_receipt(receipt)
          write_json(receipt_path(receipt.fetch("idempotency_key")), receipt)
          @receipts[receipt.fetch("idempotency_key")] = receipt
        end

        def retire(spool_entry_id)
          record = @entries.delete(spool_entry_id)
          return nil if record.nil?

          FileUtils.rm_f(entry_path(spool_entry_id))
          record
        end

        private

        def load_producer
          stored = read_json(File.join(@dir, PRODUCER_FILE)) || {}
          @producer_key = stored["producer_key"] || "producer-#{SecureRandom.hex(8)}"
          @producer_epoch = stored.fetch("epoch", 0) + 1
          @sequence = stored.fetch("sequence", 0)
          write_producer
        end

        def write_producer
          write_json(File.join(@dir, PRODUCER_FILE),
                     "producer_key" => @producer_key, "epoch" => @producer_epoch, "sequence" => @sequence)
        end

        def load_entries
          records = Dir[File.join(entries_dir, "*.json")].filter_map { |path| read_json(path) }
          records.sort_by { |record| [record.fetch("producer_epoch"), record.fetch("producer_sequence")] }
                 .each_with_object({}) { |record, index| index[record.fetch("spool_entry_id")] = record }
        end

        def load_receipts
          Dir[File.join(receipts_dir, "*.json")].filter_map { |path| read_json(path) }
                                                .each_with_object({}) do |record, index|
            index[record.fetch("idempotency_key")] = record
          end
        end

        def entries_dir
          File.join(@dir, ENTRIES_DIR)
        end

        def receipts_dir
          File.join(@dir, RECEIPTS_DIR)
        end

        def entry_path(spool_entry_id)
          File.join(entries_dir, "#{spool_entry_id}.json")
        end

        # The idempotency key is actor-supplied text, so it is hashed rather than used as
        # a file name directly.
        def receipt_path(idempotency_key)
          File.join(receipts_dir, "#{Digest::SHA256.hexdigest(idempotency_key)}.json")
        end

        def read_json(path)
          JSON.parse(File.binread(path))
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        # Durable means it survives the producer process, so the bytes are flushed to the
        # device before the caller is told the entry is queued.
        def write_json(path, record)
          File.open(path, "wb") do |file|
            file.write(JSON.generate(record))
            file.flush
            file.fsync
          end
        end
      end
    end
  end
end
