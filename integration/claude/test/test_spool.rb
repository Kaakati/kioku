# frozen_string_literal: true

require_relative "test_helper"

class TestSpool < Minitest::Test
  def with_spool(max_bytes: 1_048_576)
    Dir.mktmpdir("kioku-spool") do |dir|
      yield Kioku::Spool.new(dir: dir, producer_key: "producer-1", max_bytes: max_bytes)
    end
  end

  def test_enqueue_returns_a_receipt_that_is_not_saved
    with_spool do |spool|
      receipt = spool.enqueue(kind: "context_remember", payload: { "a" => 1 })
      assert_match(/\A[0-9a-f-]{36}\z/, receipt.spool_entry_id)
      assert_equal "producer-1", receipt.producer_key
      assert_equal false, receipt.to_h["saved"]
    end
  end

  def test_sequence_is_monotonic_and_entries_replay_in_order
    with_spool do |spool|
      3.times { |index| spool.enqueue(kind: "capture", payload: { "n" => index }) }
      sequences = spool.pending.map { |entry| entry.record["producer_sequence"] }
      assert_equal [1, 2, 3], sequences
      assert_equal [0, 1, 2], spool.pending.map { |entry| entry.record.dig("payload", "n") }
    end
  end

  # Epochs count agent lifetimes, not writes: a short-lived hook process reads
  # the current epoch rather than bumping it.
  def test_epoch_is_bumped_per_agent_start_not_per_enqueue
    with_spool do |spool|
      assert_equal 1, spool.start_epoch!
      spool.enqueue(kind: "capture", payload: {})
      spool.enqueue(kind: "capture", payload: {})
      assert_equal 1, spool.epoch

      assert_equal 2, spool.start_epoch!
      assert_equal 2, spool.enqueue(kind: "capture", payload: {}).producer_epoch
      assert_equal [1, 1, 2], spool.pending.map { |entry| entry.record["producer_epoch"] }
    end
  end

  def test_records_are_durable_json_on_disk
    with_spool do |spool|
      spool.enqueue(kind: "capture", payload: { "cwd" => "/tmp/x" }, binding_state: "resolved")
      entry = spool.pending.first
      reloaded = JSON.parse(File.read(entry.path))
      assert_equal "resolved", reloaded["binding_state"]
      assert_equal false, reloaded["saved"]
    end
  end

  # Only a canonical receipt retires an entry.
  def test_acknowledge_retires_only_the_named_entry
    with_spool do |spool|
      first = spool.enqueue(kind: "capture", payload: { "n" => 1 })
      spool.enqueue(kind: "capture", payload: { "n" => 2 })
      assert spool.acknowledge(first.spool_entry_id, receipt: { "receipt_id" => "r-1" })
      assert_equal 1, spool.stats["pending_count"]
      assert_equal 1, spool.stats["done_count"]
      refute spool.acknowledge("not-a-real-entry", receipt: { "receipt_id" => "r-2" })
    end
  end

  # Disk exhaustion produces visible failure, never a false durable acknowledgment.
  def test_a_full_spool_fails_visibly_and_keeps_every_pending_record
    with_spool(max_bytes: 900) do |spool|
      written = 0
      error = nil
      20.times do
        spool.enqueue(kind: "capture", payload: { "body" => "x" * 64 })
        written += 1
      rescue Kioku::Error => e
        error = e
        break
      end

      refute_nil error, "expected the bounded spool to refuse a write"
      assert_equal "kioku.quota_exhausted", error.code
      assert_equal "spool_bytes", error.details["quota_kind"]
      assert_equal written, spool.stats["pending_count"]
    end
  end

  def test_acknowledged_entries_are_reclaimed_before_refusing
    Dir.mktmpdir("kioku-spool") do |dir|
      probe = Kioku::Spool.new(dir: dir, producer_key: "producer-1", max_bytes: 10_000_000)
      first = probe.enqueue(kind: "capture", payload: { "body" => "x" * 200 })
      record_bytes = probe.stats["pending_bytes"]
      probe.acknowledge(first.spool_entry_id, receipt: { "receipt_id" => "r-1" })
      done_bytes = probe.stats["done_bytes"]

      # A bound with room for the acknowledged entry plus exactly one new one.
      spool = Kioku::Spool.new(dir: dir, producer_key: "producer-1", max_bytes: done_bytes + record_bytes + 64)
      spool.enqueue(kind: "capture", payload: { "body" => "y" * 200 })
      assert_equal 1, spool.stats["done_count"]

      # This one only fits once the acknowledged entry is reclaimed.
      spool.enqueue(kind: "capture", payload: { "body" => "z" * 200 })
      assert_equal 0, spool.stats["done_count"]
      assert_equal 2, spool.stats["pending_count"]
    end
  end

  def test_stats_report_the_bound
    with_spool(max_bytes: 4_096) do |spool|
      assert_equal 4_096, spool.stats["max_bytes"]
      assert_equal "producer-1", spool.stats["producer_key"]
    end
  end
end
