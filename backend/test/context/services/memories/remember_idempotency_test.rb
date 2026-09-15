# frozen_string_literal: true

require "test_helper"

# Plan 7.1 ("Repeating the same idempotency key and payload returns the prior
# receipt; a different payload conflicts"), invariant 4 ("revisions are
# immutable; stale writers fail their expected-revision check") and the frozen
# contract's kioku.idempotency_conflict / kioku.revision_conflict entries.
class RememberIdempotencyTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport

  BODY = "Two workers claimed the same invoice lease; the retry double-charged."

  setup do
    arrange_project_with_durable_evidence
  end

  test "should return the prior receipt and append no second revision when the same key replays the same digest" do
    service = remember_service
    first = service.call(**remember_arguments)

    replay = service.call(**remember_arguments(envelope: mutation_envelope(idempotency_key: "idem-1")))

    assert_predicate replay.receipt, :replayed?
    assert_equal first.receipt.receipt_id, replay.receipt.receipt_id
    assert_equal first.memory_key, replay.memory_key
    assert_equal first.revision, replay.revision
    assert_equal 1, revisions_for(first.memory_key).count
  end

  test "should enqueue no second outbox event when the same key replays the same digest" do
    outbox = fake_outbox
    service = remember_service(outbox: outbox)
    service.call(**remember_arguments)

    service.call(**remember_arguments(envelope: mutation_envelope(idempotency_key: "idem-1")))

    assert_equal 1, outbox.events.size
  end

  test "should conflict and leave the stored body untouched when the same key arrives with a different digest" do
    service = remember_service
    first = service.call(**remember_arguments)
    conflicting_envelope = mutation_envelope(idempotency_key: "idem-1",
                                             request_digest: request_digest_for("a different payload"))

    result = service.call(**remember_arguments(envelope: conflicting_envelope,
                                               body: "A different conclusion entirely."))

    assert_equal :conflict, result.status
    assert_equal "kioku.idempotency_conflict", result.error_code
    refute_predicate result, :saved?
    assert_equal 1, revisions_for(first.memory_key).count
    assert_equal BODY, revisions_for(first.memory_key).first.body
  end

  test "should conflict and append no revision when expected_revision is stale" do
    create_memory(memory_key: "memory-1", revisions: 2)

    result = remember_service.call(
      **remember_arguments(memory_key: "memory-1",
                           envelope: mutation_envelope(idempotency_key: "idem-stale", expected_revision: 1))
    )

    assert_equal :conflict, result.status
    assert_equal "kioku.revision_conflict", result.error_code
    assert_equal 2, result.error_details[:current_revision]
    assert_equal 2, revisions_for("memory-1").count
    assert_equal 2, memory_record("memory-1").current_revision
  end

  test "should write no idempotency receipt when expected_revision is stale" do
    create_memory(memory_key: "memory-1", revisions: 2)

    remember_service.call(
      **remember_arguments(memory_key: "memory-1",
                           envelope: mutation_envelope(idempotency_key: "idem-stale", expected_revision: 1))
    )

    assert_equal 0, receipt_count("idem-stale")
  end
end
