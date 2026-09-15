# frozen_string_literal: true

require "test_helper"

# Plan 7.1 step 5: "A short transaction commits event/revision/head/search
# projection, outbox and idempotency receipt." Plan 5.1: "An event and its
# canonical outbox rows commit together."
#
# Every existing assertion about that pairing runs against Kioku::Test::FakeOutbox
# — an array that cannot be rolled back, cannot collide and cannot be read by the
# dispatcher. These cases run `Remember` against the real writer, so the outbox
# row the caller is told about (`data.outbox_event_id`) is a row that actually
# exists and carries the change it announces.
#
# FakeOutbox keeps its job: injecting a fault at the seam. It is not evidence
# that a durable row was written.
class RememberOutboxCommitTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport
  include Kioku::Test::PersistenceActors

  setup do
    arrange_project_with_durable_evidence
  end

  test "should commit one outbox row naming the revision it announces" do
    # Arrange / Act
    result = durable_remember.call(**remember_arguments(actor: writing_actor(principal_id: "actor-a")))

    # Assert
    assert_predicate result, :saved?
    row = OutboxEvent.find_by(outbox_event_id: result.outbox_event_id)
    assert_equal "kioku.memory.revision_committed", row.event_type
    assert_equal result.memory_key, row.payload["memory_key"]
    assert_equal result.revision, row.payload["revision"]
    assert_equal Kioku::Test::Factories::PRIMARY_PROJECT_KEY, row.project_key
    assert_equal "pending", row.dispatch_state
  end

  test "should record no second outbox row when the same idempotency key replays" do
    # Arrange — a replay returns the prior receipt and writes nothing, so it must
    # not schedule the work a second time either (plan 7.1).
    actor = writing_actor(principal_id: "actor-a")
    durable_remember.call(**remember_arguments(actor: actor))

    # Act
    replay = durable_remember.call(**remember_arguments(actor: actor,
                                                        envelope: mutation_envelope(idempotency_key: "idem-1")))

    # Assert
    assert_predicate replay.receipt, :replayed?
    assert_equal 1, OutboxEvent.count
  end

  test "should record one outbox row per committed revision when two memories are saved" do
    # Arrange — the work key is the identity of the change, not of the table; two
    # different changes cannot share one (plan 5.1, "stable work keys").
    actor = writing_actor(principal_id: "actor-a")

    # Act
    first = durable_remember.call(**remember_arguments(actor: actor))
    second = durable_remember.call(**remember_arguments(
      actor: actor, envelope: mutation_envelope(idempotency_key: "idem-2"),
      title: "Lease renewal starves the reaper",
      body: "The reaper never ran because every renewal reset its clock."
    ))

    # Assert
    assert_equal 2, OutboxEvent.count
    assert_equal [first.outbox_event_id, second.outbox_event_id].sort,
                 OutboxEvent.pluck(:outbox_event_id).sort
  end

  private

  # The object store stays a double — object durability is not the subject here —
  # while the outbox is the real writer.
  def durable_remember
    Context::Services::Memories::Remember.new(
      object_store: fake_object_store(durable: [Kioku::Test::Factories::DURABLE_OBJECT_KEY]),
      outbox: Context::Storage::Outbox.new
    )
  end
end
