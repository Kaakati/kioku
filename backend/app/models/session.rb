# frozen_string_literal: true

# A provider coding session. Its project binding stays NULL until the registered
# root/worktree mapping resolves one (Plan §1.2); an unresolved binding is never
# read as permission to use the global store. A project switch advances
# `context_epoch`, which invalidates delivery caches.
class Session < ApplicationRecord
  belongs_to :installation
  belongs_to :project, primary_key: :project_key, foreign_key: :project_key, optional: true

  has_many :agents, primary_key: :session_key, foreign_key: :session_key,
                    inverse_of: :session, dependent: :restrict_with_error
  has_many :events, primary_key: :session_key, foreign_key: :session_key,
                    dependent: :restrict_with_error

  validates :session_key, presence: true, uniqueness: true
  validates :provider_session_id, presence: true,
                                  uniqueness: { scope: :installation_id }
  validates :context_epoch, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :ended_at_not_before_started_at

  def project_bound?
    project_key.present?
  end

  # At most one main agent per session, enforced by the partial unique index
  # "one_main_agent_per_session".
  def main_agent
    agents.find_by(agent_kind: "main")
  end

  private

  def ended_at_not_before_started_at
    return if ended_at.nil? || started_at.nil? || ended_at >= started_at

    errors.add(:ended_at, "cannot be before started_at")
  end
end
