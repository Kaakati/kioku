# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Kioku
  # The durable bounded host spool.
  #
  # Two rules govern it and neither bends. `queued` means the record is durably
  # on disk here and nothing more; only a canonical receipt from the core makes
  # it `saved`. And a durable unacknowledged record is never discarded to make
  # room: when the bound is reached the spool reclaims acknowledged entries
  # first and then fails visibly with kioku.quota_exhausted, because a silent
  # eviction is indistinguishable to the caller from a false save.
  #
  # Entries are files, one per record, moved into place with rename after
  # fsync, so a crash mid-write leaves a temp file rather than a half record.
  # Sequence allocation is flock'd, so context-agent and a short-lived
  # contextctl hook can enqueue into the same producer stream safely.
  class Spool
    Receipt = Struct.new(:spool_entry_id, :producer_key, :producer_epoch, :producer_sequence, keyword_init: true) do
      def to_h
        {
          "spool_entry_id" => spool_entry_id, "producer_key" => producer_key,
          "producer_epoch" => producer_epoch, "producer_sequence" => producer_sequence,
          "saved" => false
        }
      end
    end

    Entry = Struct.new(:path, :record, keyword_init: true)

    def initialize(dir:, producer_key:, max_bytes:)
      @dir = dir
      @producer_key = producer_key
      @max_bytes = max_bytes
      FileUtils.mkdir_p([pending_dir, done_dir, tmp_dir], mode: 0o700)
    end

    attr_reader :producer_key

    # Bumped once per context-agent start. A short-lived hook process reads the
    # current value instead of bumping, so epochs count agent lifetimes.
    def start_epoch!
      next_counter(epoch_path)
    end

    def epoch
      read_counter(epoch_path)
    end

    def enqueue(kind:, payload:, binding_state: "unresolved")
      sequence = next_counter(sequence_path)
      entry_id = Kioku::Ids.uuid7
      record = build_record(entry_id, sequence, kind, payload, binding_state)
      body = JSON.generate(record)
      reserve!(body.bytesize)
      persist(entry_id, sequence, body)
      Receipt.new(spool_entry_id: entry_id, producer_key: @producer_key,
                  producer_epoch: record["producer_epoch"], producer_sequence: sequence)
    end

    def pending
      Dir.children(pending_dir).sort.filter_map { |name| load_entry(File.join(pending_dir, name)) }
    end

    # Only a canonical receipt retires an entry.
    def acknowledge(entry_id, receipt:)
      entry = pending.find { |item| item.record["spool_entry_id"] == entry_id }
      return false if entry.nil?

      entry.record["receipt"] = receipt
      entry.record["acknowledged_at"] = Time.now.utc.iso8601(3)
      File.write(File.join(done_dir, File.basename(entry.path)), JSON.generate(entry.record))
      File.unlink(entry.path)
      true
    end

    def stats
      {
        "producer_key" => @producer_key, "producer_epoch" => epoch,
        "pending_count" => Dir.children(pending_dir).length,
        "pending_bytes" => directory_bytes(pending_dir),
        "done_count" => Dir.children(done_dir).length,
        "done_bytes" => directory_bytes(done_dir),
        "total_bytes" => total_bytes,
        "max_bytes" => @max_bytes
      }
    end

    private

    def pending_dir = File.join(@dir, "pending")
    def done_dir = File.join(@dir, "done")
    def tmp_dir = File.join(@dir, "tmp")
    def epoch_path = File.join(@dir, "epoch")
    def sequence_path = File.join(@dir, "sequence")

    def build_record(entry_id, sequence, kind, payload, binding_state)
      {
        "spool_entry_id" => entry_id, "producer_key" => @producer_key,
        "producer_epoch" => epoch, "producer_sequence" => sequence,
        "kind" => kind, "binding_state" => binding_state,
        "enqueued_at" => Time.now.utc.iso8601(3), "saved" => false, "payload" => payload
      }
    end

    # The bound covers the whole spool, because disk is what actually runs out.
    # Acknowledged entries are reclaimed first; pending entries are never
    # touched, so the spool refuses the write rather than quietly losing a
    # durable record that was already reported as queued.
    def reserve!(bytes)
      return if total_bytes + bytes <= @max_bytes

      reclaim_done
      observed = total_bytes
      return if observed + bytes <= @max_bytes

      raise Kioku::Error.new(
        "kioku.quota_exhausted",
        "host spool is full of unacknowledged records; nothing was enqueued",
        details: { "quota_kind" => "spool_bytes", "limit" => @max_bytes, "observed" => observed }
      )
    end

    def total_bytes
      directory_bytes(pending_dir) + directory_bytes(done_dir)
    end

    def reclaim_done
      Dir.children(done_dir).sort.each { |name| File.unlink(File.join(done_dir, name)) }
    rescue SystemCallError
      nil
    end

    def persist(entry_id, sequence, body)
      temp = File.join(tmp_dir, "#{entry_id}.json")
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(body)
        file.fsync
      end
      File.rename(temp, File.join(pending_dir, format("%020d-%s.json", sequence, entry_id)))
      sync_directory(pending_dir)
    end

    def load_entry(path)
      record = JSON.parse(File.read(path))
      Entry.new(path: path, record: record)
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def directory_bytes(dir)
      Dir.children(dir).sum { |name| File.size(File.join(dir, name)) }
    rescue SystemCallError
      0
    end

    def next_counter(path)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        value = file.read.to_i + 1
        file.rewind
        file.truncate(0)
        file.write(value.to_s)
        file.fsync
        value
      end
    end

    def read_counter(path)
      File.file?(path) ? [File.read(path).to_i, 1].max : 1
    rescue SystemCallError
      1
    end

    # Renaming into a directory is only durable once the directory entry is
    # flushed. Not every platform permits opening a directory; a host that
    # refuses still gets the fsync'd file plus atomic rename.
    def sync_directory(dir)
      File.open(dir) { |handle| handle.fsync }
    rescue SystemCallError, Errno::EACCES, IOError
      nil
    end
  end
end
