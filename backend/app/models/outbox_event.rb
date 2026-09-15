# frozen_string_literal: true

# One durable announcement of a committed canonical change (plan 3 topology:
# "durable outbox/work intent"; plan 5.1: "An event and its canonical outbox rows
# commit together").
#
# `work_key` is the identity of the work, not of the row, so re-recording
# already-accepted work collides instead of scheduling a second job for the same
# revision. There is deliberately NO uniqueness validation on it: a
# read-then-write check cannot arbitrate between two concurrent writers, the
# unique index can, and a validation would only convert the index's decision into
# a race-dependent error class.
class OutboxEvent < ApplicationRecord
  self.primary_key = "outbox_event_id"

  # Plan 5.1: "Track pending/dispatched/completed state ... Failed work has
  # bounded retry limits and a visible terminal state rather than infinite
  # reconciliation." A row outside the three is work no reconciler can classify.
  DISPATCH_STATES = %w[pending dispatched completed].freeze

  validates :work_key, presence: true
  validates :event_type, presence: true
  validates :recorded_at, presence: true
  validates :dispatch_state, inclusion: { in: DISPATCH_STATES }
end
