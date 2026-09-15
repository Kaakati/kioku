# frozen_string_literal: true

# The durable outbox (plan 3 topology: "durable outbox/work intent"; plan 5.1:
# "An event and its canonical outbox rows commit together ... Track
# pending/dispatched/completed state and stable work keys"; plan 7.1 step 5).
#
# Plan 5.1 names the shortcut this table exists to refuse: "Merely using
# `after_commit` or Active Job's deferred enqueue does not make commit and
# scheduling atomic." A row here is written by the same transaction as the domain
# change it announces, so the two cannot disagree.
#
# `work_key` is the identity of the WORK; `outbox_event_id` is the identity of
# the ROW. Keeping them apart is what makes a redispatch after a crash harmless:
# a reconciliation loop that re-records already-accepted work collides on the
# work key instead of scheduling the same job twice ("Duplicate deliveries must
# have no duplicate domain effect").
class CreateOutboxEvents < ActiveRecord::Migration[8.1]
  DISPATCH_STATES = %w[pending dispatched completed].freeze

  def change
    create_table :outbox_events, id: :text, primary_key: :outbox_event_id do |t|
      t.text :work_key, null: false
      t.text :event_type, null: false
      t.jsonb :payload, null: false
      # Plan 5.3: project ownership travels with every row, so a scoped replay
      # stays authorizable. NULL for a global record, which owns no project.
      t.text :project_key
      t.text :dispatch_state, null: false
      t.timestamptz :recorded_at, null: false
    end

    add_index :outbox_events, :work_key, unique: true
    add_index :outbox_events, :project_key
    add_foreign_key :outbox_events, :projects, column: :project_key,
                                               primary_key: :project_key
    # A state outside the three is invisible to both the dispatcher and the
    # reconciler, which is the lost accepted event plan 5.1 forbids.
    add_check_constraint :outbox_events,
                         "dispatch_state IN (#{quoted(DISPATCH_STATES)})",
                         name: "outbox_events_dispatch_state_vocabulary"
  end

  private

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end
end
