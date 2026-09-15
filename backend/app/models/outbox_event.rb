# frozen_string_literal: true

# One durable unit of work intent (Plan §5.1, §7.1).
#
# The domain mutation and its outbox row commit in the same transaction, so a
# crash between commit and enqueue loses nothing. Redis owns queue and retry
# scheduling; this row owns durable intent, the execution lease and the terminal
# state a bounded reconciliation loop can recover from.
class OutboxEvent < ApplicationRecord
  STATES = %w[pending dispatched completed failed].freeze

  include OwnershipDestination

  belongs_to :installation
  belongs_to :event, primary_key: :event_key, foreign_key: :event_key, optional: true

  validates :outbox_event_key, presence: true, uniqueness: true
  validates :job_class, presence: true
  validates :state, inclusion: { in: STATES }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :available_at, presence: true
  validate :lease_is_whole
  validate :completed_at_matches_state

  scope :claimable, ->(now = Time.current) { where(state: "pending").where(available_at: ..now) }
  scope :lease_expired, ->(now = Time.current) { where(state: "dispatched").where(lease_expires_at: ...now) }

  def leased?
    lease_owner.present?
  end

  def retries_exhausted?
    attempts >= max_attempts
  end

  private

  def lease_is_whole
    return if lease_owner.nil? == lease_expires_at.nil?

    errors.add(:lease_owner, "and lease_expires_at must be set together")
  end

  def completed_at_matches_state
    return if (state == "completed") == completed_at.present?

    errors.add(:completed_at, "must be set exactly when the state is \"completed\"")
  end
end
