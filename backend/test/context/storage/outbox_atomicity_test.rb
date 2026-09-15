# frozen_string_literal: true

require "test_helper"

# Context::Storage::Outbox — the real writer behind plan 5.1's "An event and its
# canonical outbox rows commit together".
#
# The existing durability suite injects a failure at the outbox seam and asserts
# the domain write rolls back. That proves one direction with a double. The
# direction that actually loses work is the other one: the outbox row commits and
# the domain change does not, so a job is scheduled for a revision nobody can
# read. Nothing in the suite exercises it, because the only outbox that exists is
# an in-memory array which no database failure can reach.
#
# Plan 5.1 names the shortcut this forbids: "Merely using `after_commit` or
# Active Job's deferred enqueue does not make commit and scheduling atomic."
# `record` therefore participates in the caller's transaction and never opens one
# of its own, which the last case below observes directly.
class OutboxAtomicityTest < ActiveSupport::TestCase
  EVENT_TYPE = "kioku.memory.revision_committed"
  PAYLOAD = { memory_key: "memory-1", revision: 1, store_kind: "project" }.freeze

  setup do
    assert_canonical_schema_present
    @installation = seed_installation
    @project = seed_project
  end

  test "should persist no outbox row when a later write in the same transaction is refused" do
    # Arrange
    work_key = "memory-1:1"

    # Act — the outbox row is recorded, then the database refuses the capture
    # event that the same transaction exists to write.
    assert_database_rejects(because: [PG::CheckViolation],
                            describing: "the domain write that follows the outbox row") do
      outbox.record(event_type: EVENT_TYPE, payload: PAYLOAD, project_key: @project,
                    work_key: work_key)
      seed_event(installation_key: @installation, origin_role: "subagent")
    end

    # Assert — no domain change, therefore no announcement of one.
    assert_equal 0, outbox_rows(work_key)
  end

  test "should persist the outbox row when the transaction that wrote it commits" do
    # Arrange
    work_key = "memory-2:1"
    recorded_id = nil

    # Act
    ActiveRecord::Base.transaction(requires_new: true) do
      recorded_id = outbox.record(event_type: EVENT_TYPE, payload: PAYLOAD,
                                  project_key: @project, work_key: work_key)
    end

    # Assert — the identifier handed back is the row, because context_remember
    # reports it to the caller as data.outbox_event_id; an id that names no row
    # is a receipt for work that was never queued.
    row = OutboxEvent.find_by(work_key: work_key)
    assert_equal recorded_id, row.outbox_event_id
    assert_equal EVENT_TYPE, row.event_type
    assert_equal({ "memory_key" => "memory-1", "revision" => 1, "store_kind" => "project" },
                 row.payload)
    assert_equal @project, row.project_key
    assert_equal "pending", row.dispatch_state,
                 "An undispatched row must be claimable by the reconciliation loop (plan 5.1)."
  end

  test "should join the caller's transaction rather than opening one of its own" do
    # Arrange — a savepoint of our own, so the probe is shown to detect the very
    # thing the assertion below denies. Without this control the assertion would
    # pass against a probe that sees nothing at all.
    ActiveRecord::Base.transaction(requires_new: true) do
      control = transaction_statements do
        ActiveRecord::Base.transaction(requires_new: true) { seed_project }
      end
      refute_empty control, "The probe cannot see a nested transaction; it proves nothing below."

      # Act
      observed = transaction_statements do
        outbox.record(event_type: EVENT_TYPE, payload: PAYLOAD, project_key: @project,
                      work_key: "memory-3:1")
      end

      # Assert — a transaction of its own (including a savepoint) would let the
      # row survive a rollback the caller performs for the domain write.
      assert_empty observed,
                   "Outbox#record issued its own transaction control: #{observed.inspect}. " \
                   "It must write inside the caller's transaction (plan 5.1)."
    end
  end

  private

  def outbox
    @outbox ||= Context::Storage::Outbox.new
  end

  # Transaction control statements (BEGIN, SAVEPOINT, RELEASE SAVEPOINT) are
  # instrumented by Active Record under the reserved statement name
  # "TRANSACTION", which is how `rails` logs them. Collecting them around a call
  # is the only way to tell a write that joined the caller's transaction from one
  # that opened a savepoint of its own: both roll back identically, so no
  # assertion about surviving rows can separate them.
  def transaction_statements
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:name] == "TRANSACTION"
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def outbox_rows(work_key)
    row_count("outbox_events", ActiveRecord::Base.sanitize_sql_array(["work_key = ?", work_key]))
  end
end
