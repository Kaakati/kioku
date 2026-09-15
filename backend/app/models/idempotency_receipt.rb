# frozen_string_literal: true

# The receipt one idempotency key resolves to (plan 7.1 step 5).
#
# The key is ACTOR-SCOPED (frozen contract, envelope.idempotency_key), so the row
# records who wrote it: (installation_key, actor_principal_id, idempotency_key)
# is the scope, and the principal alone is not one — two installations mint
# principals independently.
#
# Plan 7.1: "Repeating the same idempotency key and payload returns the prior
# receipt; a different payload conflicts." The unique index over that scope is
# what makes that a decision rather than a race, and it is deliberately the ONLY
# enforcement here: a uniqueness validation reads before it writes, so under two
# concurrent writers it either misses the collision or reports it as a validation
# failure depending on which committed first. The service arbitrates a lost
# insert against the committed receipt; it cannot arbitrate against a coin flip.
class IdempotencyReceipt < ApplicationRecord
  self.primary_key = "receipt_id"

  validates :idempotency_key, presence: true
  validates :installation_key, presence: true
  validates :actor_principal_id, presence: true
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
