# frozen_string_literal: true

require_relative "../test_helper"
require "kioku/agent/spool"

# The durable bounded spool [plan §3 diagram "Durable bounded spool"; §7.1 steps 2 and 6].
# "queued means durable host enqueue; saved means canonical commit. A timeout or missing
# acknowledgment is never reported as a save" [plan invariant 2; contracts: errors kioku.queued].
class KiokuAgentSpoolTest < Minitest::Test
  BODY = "x" * 4_096

  def open_spool(dir, max_bytes: 10_000_000)
    Kioku::Agent::Spool.new(dir: dir, max_bytes: max_bytes)
  end

  def capture(index = 0)
    {
      "tool" => "context_remember",
      "envelope" => mutation_envelope,
      "kind" => "decision",
      "title" => "capture #{index}",
      "body" => BODY
    }
  end

  def enqueue(spool, index = 0, key: "idem-#{index}", digest: valid_request_digest("payload-#{index}"))
    spool.enqueue(envelope: capture(index), idempotency_key: key, request_digest: digest)
  end

  def canonical_receipt(key, digest)
    {
      "receipt_id" => "receipt-#{key}",
      "idempotency_key" => key,
      "request_digest" => digest,
      "committed_at" => "2026-09-15T10:00:02Z",
      "replayed" => false
    }
  end

  # The distinction that the whole system rests on.
  def test_should_report_the_write_as_unsaved_when_an_entry_is_durably_enqueued
    with_workspace do |dir|
      receipt = enqueue(open_spool(dir))

      assert_equal "queued", receipt.status
      refute_predicate receipt, :saved?
      assert_nil receipt.canonical_receipt
    end
  end

  def test_should_carry_the_producer_identity_fields_when_an_entry_is_enqueued
    with_workspace do |dir|
      receipt = enqueue(open_spool(dir))

      refute_nil receipt.spool_entry_id
      refute_nil receipt.producer_key
      assert_kind_of Integer, receipt.producer_epoch
      assert_kind_of Integer, receipt.producer_sequence
    end
  end

  # Durable means it survives the producer process, not merely the method call.
  def test_should_still_hold_the_entry_when_the_spool_is_reopened_from_disk
    with_workspace do |dir|
      receipt = enqueue(open_spool(dir), 1)

      reopened = open_spool(dir)
      entry = reopened.pending.find { |pending| pending.spool_entry_id == receipt.spool_entry_id }

      refute_nil entry, "the entry acknowledged as queued did not survive a reopen"
      assert_equal "capture 1", entry.envelope.fetch("title")
    end
  end

  # "assigns stable producer sequence/correlation metadata" [plan §7.1 step 2].
  def test_should_assign_strictly_increasing_sequence_numbers_when_entries_are_enqueued
    with_workspace do |dir|
      spool = open_spool(dir)
      sequences = (0..2).map { |index| enqueue(spool, index).producer_sequence }

      assert_equal sequences.sort, sequences
      assert_equal sequences.uniq, sequences
    end
  end

  # Reconnect epochs distinguish a restarted producer's sequence numbers from the
  # previous run's [plan §3.1 "reconnect epochs"].
  def test_should_advance_the_producer_epoch_when_the_spool_is_reopened
    with_workspace do |dir|
      first = enqueue(open_spool(dir), 0)
      second = enqueue(open_spool(dir), 1)

      assert_operator second.producer_epoch, :>, first.producer_epoch
    end
  end

  def test_should_keep_the_producer_key_stable_when_the_spool_is_reopened
    with_workspace do |dir|
      first = enqueue(open_spool(dir), 0)
      second = enqueue(open_spool(dir), 1)

      assert_equal first.producer_key, second.producer_key
    end
  end

  # "durable unacknowledged records must not be silently discarded to make room"
  # [plan §7.1]; "Disk/spool full ... never produces a false durable acknowledgment"
  # [contracts: errors kioku.quota_exhausted; plan §9].
  def test_should_refuse_the_enqueue_rather_than_evict_unacknowledged_entries_when_the_spool_is_full
    with_workspace do |dir|
      spool = open_spool(dir, max_bytes: 32_768)
      accepted, error = fill_until_refused(spool)

      assert_equal "kioku.quota_exhausted", error.code
      surviving = spool.pending.map(&:spool_entry_id)
      accepted.each do |receipt|
        assert_includes surviving, receipt.spool_entry_id,
                        "an unacknowledged entry was discarded to make room"
      end
    end
  end

  def test_should_report_the_observed_and_permitted_bytes_when_the_spool_refuses_for_quota
    with_workspace do |dir|
      spool = open_spool(dir, max_bytes: 32_768)
      _accepted, error = fill_until_refused(spool)

      assert_equal "spool_disk", error.details["quota_kind"]
      assert_equal 32_768, error.details["limit"]
      assert_kind_of Integer, error.details["observed"]
    end
  end

  # Non-vacuousness: the bound is reclaimable, so refusal is about acknowledgment
  # state rather than a permanently wedged spool.
  def test_should_accept_a_new_entry_when_acknowledged_entries_have_freed_space
    with_workspace do |dir|
      spool = open_spool(dir, max_bytes: 32_768)
      accepted, = fill_until_refused(spool)
      accepted.each_with_index do |receipt, index|
        spool.acknowledge(spool_entry_id: receipt.spool_entry_id,
                          canonical_receipt: canonical_receipt("idem-#{index}", valid_request_digest("payload-#{index}")))
      end

      assert_equal "queued", enqueue(spool, 900).status
    end
  end

  # "The agent acknowledges/retires spool entries only after the canonical receipt"
  # [plan §7.1 step 6].
  def test_should_keep_the_entry_pending_until_a_canonical_receipt_acknowledges_it
    with_workspace do |dir|
      spool = open_spool(dir)
      receipt = enqueue(spool, 0)

      assert_equal 1, spool.pending_count

      spool.acknowledge(spool_entry_id: receipt.spool_entry_id,
                        canonical_receipt: canonical_receipt("idem-0", valid_request_digest("payload-0")))

      assert_equal 0, spool.pending_count
    end
  end

  def test_should_refuse_the_acknowledgment_and_retain_the_entry_when_no_canonical_receipt_is_supplied
    with_workspace do |dir|
      spool = open_spool(dir)
      receipt = enqueue(spool, 0)
      incomplete = canonical_receipt("idem-0", valid_request_digest("payload-0"))
      incomplete.delete("committed_at")

      assert_raises_kioku("kioku.invalid_request", "acknowledgment without a canonical commit") do
        spool.acknowledge(spool_entry_id: receipt.spool_entry_id, canonical_receipt: incomplete)
      end
      assert_equal 1, spool.pending_count
    end
  end

  # "Repeating the same idempotency key and payload returns the prior receipt"
  # [plan §7.1]; "Lost reply or duplicate delivery | Retry-safe receipt lookup; no
  # duplicate logical mutation" [plan §9].
  def test_should_return_the_prior_receipt_without_a_second_entry_when_the_same_request_is_replayed
    with_workspace do |dir|
      spool = open_spool(dir)
      first = enqueue(spool, 0, key: "idem-a", digest: valid_request_digest("same"))
      second = enqueue(spool, 0, key: "idem-a", digest: valid_request_digest("same"))

      assert_equal first.spool_entry_id, second.spool_entry_id
      assert_equal 1, spool.pending_count
      assert_predicate second, :replayed?
    end
  end

  def test_should_replay_the_prior_receipt_when_the_spool_was_reopened_between_attempts
    with_workspace do |dir|
      first = enqueue(open_spool(dir), 0, key: "idem-a", digest: valid_request_digest("same"))
      reopened = open_spool(dir)
      second = enqueue(reopened, 0, key: "idem-a", digest: valid_request_digest("same"))

      assert_equal first.spool_entry_id, second.spool_entry_id
      assert_equal 1, reopened.pending_count
    end
  end

  # "a different payload conflicts" [plan §7.1; contracts: errors kioku.idempotency_conflict].
  def test_should_conflict_and_write_nothing_when_the_same_key_arrives_with_a_different_digest
    with_workspace do |dir|
      spool = open_spool(dir)
      enqueue(spool, 0, key: "idem-a", digest: valid_request_digest("first"))

      assert_raises_kioku("kioku.idempotency_conflict", "same key, different digest") do
        enqueue(spool, 1, key: "idem-a", digest: valid_request_digest("second"))
      end
      assert_equal 1, spool.pending_count
    end
  end

  # A lost acknowledgment: the write already committed, so the replay must hand back
  # the canonical receipt and must not re-enqueue the capture.
  def test_should_return_the_canonical_receipt_without_re_enqueuing_when_the_acknowledgment_was_lost
    with_workspace do |dir|
      spool = open_spool(dir)
      digest = valid_request_digest("same")
      first = enqueue(spool, 0, key: "idem-a", digest: digest)
      spool.acknowledge(spool_entry_id: first.spool_entry_id,
                        canonical_receipt: canonical_receipt("idem-a", digest))

      replay = enqueue(spool, 0, key: "idem-a", digest: digest)

      assert_predicate replay, :saved?
      assert_predicate replay, :replayed?
      assert_equal "receipt-idem-a", replay.canonical_receipt.fetch("receipt_id")
      assert_equal 0, spool.pending_count
    end
  end

  def test_should_report_a_committed_entry_as_saved_only_after_its_canonical_receipt_arrives
    with_workspace do |dir|
      spool = open_spool(dir)
      digest = valid_request_digest("same")
      receipt = enqueue(spool, 0, key: "idem-a", digest: digest)

      refute_predicate spool.receipt_for(idempotency_key: "idem-a"), :saved?

      spool.acknowledge(spool_entry_id: receipt.spool_entry_id,
                        canonical_receipt: canonical_receipt("idem-a", digest))

      assert_predicate spool.receipt_for(idempotency_key: "idem-a"), :saved?
    end
  end

  private

  def fill_until_refused(spool, limit: 64)
    accepted = []
    limit.times do |index|
      begin
        accepted << enqueue(spool, index)
      rescue Kioku::Error => error
        return [accepted, error]
      end
    end
    flunk("the spool accepted #{limit} entries of #{BODY.bytesize} bytes without enforcing max_bytes")
  end
end
