# frozen_string_literal: true

require "test_helper"

# The durable outbox (plan 3 topology: "durable outbox/work intent"; plan 5.1:
# "An event and its canonical outbox rows commit together ... Track
# pending/dispatched/completed state and stable work keys"; plan 7.1 step 5: "A
# short transaction commits event/revision/head/search projection, outbox and
# idempotency receipt").
#
# There is no such table today. The only implementation of the seam is
# Kioku::Test::FakeOutbox, an in-memory array, so the claim that a domain
# mutation and its outbox row commit together is asserted only against a double
# that cannot fail the way a database can. Plan 5.1 is explicit that this is not
# a detail: "Merely using `after_commit` or Active Job's deferred enqueue does
# not make commit and scheduling atomic."
#
# Names follow the wire and the plan: `outbox_event_id` is the identifier
# context_remember already reports as `data.outbox_event_id`, and `work_key` is
# plan 5.1's stable work key — the identity of the work, as opposed to the
# identity of the row, which is what makes a redispatch after a crash harmless.
#
# The inserts below name the columns this contract requires; a further column
# must be nullable or carry a default (test/support/schema_contract.rb).
class OutboxEventsTableTest < ActiveSupport::TestCase
  EVENT_TYPE = "kioku.memory.revision_committed"

  setup do
    assert_canonical_schema_present
    @project = seed_project
  end

  test "should refuse a second outbox row for a work key already recorded" do
    # Arrange — plan 5.1: "Duplicate deliveries must have no duplicate domain
    # effect." A reconciliation loop that re-records accepted work must collide
    # here rather than schedule the same job twice.
    seed_outbox_event(work_key: "memory-1:1")

    # Act / Assert
    assert_database_rejects(because: [PG::UniqueViolation],
                            describing: "a repeated stable work key") do
      seed_outbox_event(work_key: "memory-1:1")
    end
    assert_equal 1, outbox_rows("memory-1:1")
  end

  test "should accept a distinct work key for every committed change" do
    # Arrange / Act
    seed_outbox_event(work_key: "memory-1:1")
    seed_outbox_event(work_key: "memory-1:2")

    # Assert — the constraint above must bind the work, not the table.
    assert_equal 1, outbox_rows("memory-1:1")
    assert_equal 1, outbox_rows("memory-1:2")
  end

  test "should refuse a dispatch state outside the pending, dispatched and completed vocabulary" do
    # Arrange — plan 5.1: "Track pending/dispatched/completed state ... Failed
    # work has bounded retry limits and a visible terminal state rather than
    # infinite reconciliation." A state outside the three is invisible to both
    # the dispatcher and the reconciler.
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_outbox_event(work_key: "memory-2:1", dispatch_state: "enqueued")
    end
  end

  test "should refuse an outbox row that records no dispatch state" do
    # Arrange / Act / Assert — a row with no state is work the reconciler cannot
    # classify, which is the lost accepted event plan 5.1 forbids.
    assert_database_rejects(because: [PG::NotNullViolation]) do
      seed_outbox_event(work_key: "memory-3:1", dispatch_state: nil)
    end
  end

  test "should refuse an outbox row that names a project which was never registered" do
    # Arrange / Act / Assert — plan 5.3: project ownership is carried in every
    # row, and a dangling owner makes a scoped replay unauthorizable.
    assert_database_rejects(because: [PG::ForeignKeyViolation]) do
      seed_outbox_event(work_key: "memory-4:1", project_key: "never-registered")
    end
  end

  private

  def seed_outbox_event(work_key:, dispatch_state: "pending", project_key: @project,
                        event_type: EVENT_TYPE, payload: { memory_key: "memory-1", revision: 1 })
    insert_row("outbox_events",
               outbox_event_id: new_key("outbox-event"),
               work_key: work_key,
               event_type: event_type,
               payload: payload.to_json,
               project_key: project_key,
               dispatch_state: dispatch_state,
               recorded_at: Time.current)
    work_key
  end

  def outbox_rows(work_key)
    row_count("outbox_events", ActiveRecord::Base.sanitize_sql_array(["work_key = ?", work_key]))
  end
end
