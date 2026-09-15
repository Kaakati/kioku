# frozen_string_literal: true

# The receipt for one committed or durably queued mutation (Plan §7.1).
#
# Repeating an idempotency key with the same request_digest replays this row
# verbatim; a different digest is kioku.idempotency_conflict. The actor-scoped
# unique index makes that a database fact, so two concurrent writers cannot both
# believe they were first.
#
# `state` distinguishes the two honest answers: "committed" means canonically
# saved, "queued" means durably enqueued on the host spool and not yet saved.
class IdempotencyReceipt < ApplicationRecord
  STATES = %w[committed queued].freeze
  DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/
  KEY_MAX = 128

  include OwnershipDestination

  belongs_to :installation
  belongs_to :outbox_event, primary_key: :outbox_event_key, foreign_key: :outbox_event_key,
                            optional: true

  validates :receipt_key, presence: true, uniqueness: true
  validates :actor_principal_id, :operation, presence: true
  validates :idempotency_key, presence: true, length: { maximum: KEY_MAX },
                              uniqueness: { scope: %i[installation_id actor_principal_id] }
  validates :request_digest, format: { with: DIGEST_FORMAT }
  validates :state, inclusion: { in: STATES }
  validate :committed_at_matches_state

  def saved?
    state == "committed"
  end

  # True when a replay of the same key carries the same payload, which is the
  # only case in which the prior receipt may be returned verbatim.
  def replayable_for?(digest)
    request_digest == digest
  end

  private

  def committed_at_matches_state
    return if (state == "committed") == committed_at.present?

    errors.add(:committed_at, "must be set exactly when the state is \"committed\"")
  end
end
