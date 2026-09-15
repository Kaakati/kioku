# frozen_string_literal: true

# The receipt one idempotency key resolves to (plan 7.1 step 5).
#
# Plan 7.1: "Repeating the same idempotency key and payload returns the prior
# receipt; a different payload conflicts." The unique index on idempotency_key is
# what makes that a decision rather than a race; this model only refuses the
# obviously incomplete row.
class IdempotencyReceipt < ApplicationRecord
  self.primary_key = "receipt_id"

  validates :idempotency_key, presence: true, uniqueness: true
  validates :request_digest, presence: true
  validates :committed_at, presence: true
  validate :outcome_is_whole

  private

  # Half of a composite key is a reference that resolves to nothing.
  def outcome_is_whole
    return if memory_key.blank? == revision.blank?

    errors.add(:revision, "and memory_key name the outcome together or not at all")
  end
end
