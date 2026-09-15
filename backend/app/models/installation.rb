# frozen_string_literal: true

# One Kioku installation: the boundary that owns the global engineering
# namespace, the project registry and the installation-wide generations
# reported in the tool envelope's generation_vector (Plan §5.1).
class Installation < ApplicationRecord
  has_many :projects, dependent: :restrict_with_error
  has_many :scopes, dependent: :restrict_with_error
  has_many :sessions, dependent: :restrict_with_error
  has_many :events, dependent: :restrict_with_error
  has_many :outbox_events, dependent: :restrict_with_error
  has_many :idempotency_receipts, dependent: :restrict_with_error

  validates :installation_key, presence: true, uniqueness: true
  validates :canonical_generation, :global_generation, :deletion_epoch,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
