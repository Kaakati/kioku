# frozen_string_literal: true

require "test_helper"

# The service half of the actor-scoped idempotency contract (frozen contract,
# envelope.idempotency_key: "string (<=128 chars, actor-scoped)").
#
# `Storage::MemoryWriter#receipt_for` looks a receipt up by key alone, so the
# scope the contract declares does not exist anywhere in the running system. The
# existing idempotency suite cannot see it: every case uses one actor and the
# literal key "idem-1", and a scope with one member is indistinguishable from no
# scope at all. Both failure modes below need a second actor to become visible.
#
# Nothing here is about a caller's right to reuse a string. Two Claude Code
# installations, or two principals in one, are independent producers: the odds of
# a collision are whatever their key generators make them, and a collision must
# not turn into "your write was saved" or into a readout of someone else's
# receipt.
class RememberActorScopeTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport
  include Kioku::Test::PersistenceActors

  SHARED_KEY = "idem-shared-across-actors"

  setup do
    arrange_project_with_durable_evidence
  end

  test "should commit a separate memory for a second actor that reuses the key with a colliding digest" do
    # Arrange — the digests collide because both envelopes describe the same
    # request shape; the callers are different.
    first = remember_service.call(**remember_arguments(actor: writing_actor(principal_id: "actor-a"),
                                                       envelope: shared_envelope))

    # Act
    second = remember_service.call(**remember_arguments(actor: writing_actor(principal_id: "actor-b"),
                                                        envelope: shared_envelope))

    # Assert — the second actor has no prior receipt, so this is a first commit
    # and not a replay of somebody else's.
    refute_predicate second.receipt, :replayed?,
                     "The second actor never wrote this memory; replaying the first actor's " \
                     "receipt reports a save that this caller did not make."
    refute_equal first.memory_key, second.memory_key
    assert_predicate second, :saved?
    assert_equal 2, memory_count
    assert_equal 2, receipt_count(SHARED_KEY)
  end

  test "should not disclose the first actor's receipt when a second actor reuses the key with a different digest" do
    # Arrange
    first = remember_service.call(**remember_arguments(actor: writing_actor(principal_id: "actor-a"),
                                                       envelope: shared_envelope))
    divergent = mutation_envelope(idempotency_key: SHARED_KEY,
                                  request_digest: request_digest_for("a second actor's payload"))

    # Act
    second = remember_service.call(**remember_arguments(actor: writing_actor(principal_id: "actor-b"),
                                                        envelope: divergent,
                                                        body: "A different conclusion entirely."))

    # Assert — the conflict details are the disclosure channel: they carry
    # receipt_id and request_digest verbatim.
    disclosed = second.error_details.to_s
    refute_includes disclosed, first.receipt.receipt_id,
                    "A second actor was shown the first actor's receipt_id."
    refute_includes disclosed, first.receipt.request_digest,
                    "A second actor was shown the first actor's request_digest."
    assert_nil second.error_code
    assert_predicate second, :saved?
    assert_equal 2, memory_count
  end

  test "should record the writing actor and installation on the receipt it commits" do
    # Arrange / Act
    result = remember_service.call(**remember_arguments(actor: writing_actor(principal_id: "actor-a"),
                                                        envelope: shared_envelope))

    # Assert — the scope has to be persisted with the receipt; a receipt that
    # does not say who wrote it cannot be looked up for one writer.
    receipt = IdempotencyReceipt.find(result.receipt.receipt_id)
    assert_equal "actor-a", receipt.actor_principal_id
    assert_equal installation_key, receipt.installation_key
  end

  test "should replay a receipt only for the actor that wrote it" do
    # Arrange — each actor commits under the same key, then each repeats it.
    first = remember_service.call(**remember_arguments(actor: writing_actor(principal_id: "actor-a"),
                                                       envelope: shared_envelope))
    second = remember_service.call(**remember_arguments(actor: writing_actor(principal_id: "actor-b"),
                                                        envelope: shared_envelope))
    refute_equal first.memory_key, second.memory_key

    # Act
    replays = %w[actor-a actor-b].map do |principal|
      remember_service.call(**remember_arguments(actor: writing_actor(principal_id: principal),
                                                 envelope: shared_envelope))
    end

    # Assert — a replay returns the caller's own prior outcome, and no fourth
    # revision is appended for either of them.
    assert_equal [first.memory_key, second.memory_key], replays.map(&:memory_key)
    assert_equal [true, true], replays.map { |replay| replay.receipt.replayed? }
    assert_equal 2, memory_count
  end

  private

  def shared_envelope
    mutation_envelope(idempotency_key: SHARED_KEY)
  end
end
