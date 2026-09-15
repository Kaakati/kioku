# frozen_string_literal: true

require_relative "../test_helper"
require "kioku/agent/spool"

# O2 — an entry the spool acknowledged as `queued` can disappear on restart with
# no loss accounting.
#
# Spool::Store#write_json writes in place: File.open(path, "wb") then flush and
# fsync, with no temp-then-rename and no directory fsync. A crash or a power loss
# during that write leaves a truncated file in entries/. Store#load_entries then
# reads the directory with `filter_map { read_json(path) }`, and read_json
# rescues JSON::ParserError to nil — so the truncated entry is silently dropped
# and the reopened spool reports a smaller pending set as if nothing had been
# there.
#
# That is the one thing the spool is not allowed to do. "queued means durable
# host enqueue only" [contracts: errors kioku.queued] is a durability claim, and
# "Disk/spool exhaustion produces visible failure and loss accounting; it never
# produces a false durable acknowledgment" [contracts: errors
# kioku.quota_exhausted; plan §9] says what happens when durability cannot be
# kept: the loss is accounted, not swallowed. A capture the caller was told was
# queued must be either pending or accounted as lost.
#
# Truncating a committed entry file to half its bytes is exactly the on-disk
# state an interrupted in-place write leaves behind, which is why the fix is
# temp-file, fsync, rename, fsync the directory — and why this case still has to
# pass afterwards, because a rename cannot undo a file that was already damaged.
class KiokuAgentSpoolLossAccountingTest < Minitest::Test
  BODY = "x" * 2_048

  def open_spool(dir)
    Kioku::Agent::Spool.new(dir: dir)
  end

  def capture(index)
    { "tool" => "context_remember", "envelope" => mutation_envelope,
      "kind" => "decision", "title" => "capture #{index}", "body" => BODY }
  end

  def enqueue(spool, index)
    spool.enqueue(envelope: capture(index), idempotency_key: "idem-#{index}",
                  request_digest: valid_request_digest("payload-#{index}"))
  end

  def test_should_account_a_truncated_entry_as_a_loss_rather_than_dropping_it_from_the_pending_set
    with_workspace do |dir|
      spool = open_spool(dir)
      receipts = (0..2).map { |index| enqueue(spool, index) }
      damaged = receipts[1].spool_entry_id
      halve_entry_file(dir, damaged)

      reopened = open_spool(dir)

      assert_includes reopened.losses.map(&:spool_entry_id), damaged,
                      "the spool told the caller #{damaged} was queued and then reopened " \
                      "without it; a durable acknowledgment that vanishes must be accounted"
      assert_equal receipts.size, reopened.pending_count + reopened.losses.size,
                   "every entry acknowledged as queued must be either pending or accounted lost"
      assert_equal [receipts[0].spool_entry_id, receipts[2].spool_entry_id].sort,
                   reopened.pending.map(&:spool_entry_id).sort,
                   "one damaged entry must not take its neighbours with it"
    end
  end

  # The receipt file survives the entry file, so after a loss the spool still
  # holds a receipt whose canonical_receipt is nil — the record that says
  # "durably enqueued, not yet committed". Answering a replay from it would be a
  # durable acknowledgment for a capture that is no longer on disk, which is the
  # one thing the spool may never do. The capture is accepted again instead.
  def test_should_re_enqueue_the_capture_when_a_replay_arrives_for_an_entry_that_was_lost
    with_workspace do |dir|
      spool = open_spool(dir)
      (0..2).each { |index| enqueue(spool, index) }
      halve_entry_file(dir, spool.pending[1].spool_entry_id)

      reopened = open_spool(dir)
      receipt = enqueue(reopened, 1)

      assert_equal 3, reopened.pending_count,
                   "the replay was answered from a receipt whose capture is gone; a spool that " \
                   "no longer holds the entry cannot report it as durably enqueued"
      refute_predicate receipt, :saved?
    end
  end

  # Non-vacuousness: loss accounting must report a loss only when there is one,
  # otherwise the assertion above would hold for a spool that reports everything
  # as lost.
  def test_should_report_no_losses_when_every_entry_file_reopens_intact
    with_workspace do |dir|
      spool = open_spool(dir)
      (0..2).each { |index| enqueue(spool, index) }

      reopened = open_spool(dir)

      assert_empty reopened.losses
      assert_equal 3, reopened.pending_count
    end
  end

  private

  # The on-disk state an interrupted in-place write produces. The file is located
  # by its entry id rather than by an assumed directory layout.
  def halve_entry_file(dir, spool_entry_id)
    path = Dir[File.join(dir, "**", "*#{spool_entry_id}*")].find { |candidate| File.file?(candidate) }
    flunk("no file on disk carries entry #{spool_entry_id}; the spool reported it as queued") if path.nil?

    bytes = File.binread(path)
    File.binwrite(path, bytes[0, bytes.bytesize / 2])
    path
  end
end
