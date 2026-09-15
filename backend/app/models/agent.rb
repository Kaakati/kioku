# frozen_string_literal: true

# A locally assigned agent identity (Research Appendix A `agents`).
#
# SQL cannot establish that an asserted provider ID genuinely came from Claude,
# so a parent is recorded only when lineage is supported: `lineage_state` and
# `parent_agent_key` move together, and unresolved agents stay unresolved rather
# than being merged into one shared "unknown agent".
class Agent < ApplicationRecord
  KINDS = %w[main subagent fork teammate unknown].freeze
  LINEAGE_STATES = %w[root known unresolved].freeze
  IDENTITY_SOURCES = %w[hook telemetry transcript bridge unresolved].freeze

  belongs_to :session, primary_key: :session_key, foreign_key: :session_key,
                       inverse_of: :agents
  belongs_to :parent_agent, class_name: "Agent", primary_key: :agent_key,
                            foreign_key: :parent_agent_key, optional: true,
                            inverse_of: :child_agents

  has_many :child_agents, class_name: "Agent", primary_key: :agent_key,
                          foreign_key: :parent_agent_key, inverse_of: :parent_agent,
                          dependent: :restrict_with_error
  has_many :agent_runs, primary_key: :agent_key, foreign_key: :agent_key,
                        inverse_of: :agent, dependent: :restrict_with_error
  has_many :events, primary_key: :agent_key, foreign_key: :agent_key,
                    dependent: :restrict_with_error

  validates :agent_key, presence: true, uniqueness: true
  validates :agent_kind, inclusion: { in: KINDS }
  validates :lineage_state, inclusion: { in: LINEAGE_STATES }
  validates :identity_source, inclusion: { in: IDENTITY_SOURCES }
  validates :provider_agent_id, uniqueness: { scope: :session_key }, allow_nil: true
  validate :parent_is_not_self
  validate :lineage_state_matches_parent

  def main?
    agent_kind == "main"
  end

  private

  def parent_is_not_self
    return if parent_agent_key.nil? || parent_agent_key != agent_key

    errors.add(:parent_agent_key, "cannot reference the agent itself")
  end

  def lineage_state_matches_parent
    return if lineage_state == "known" && parent_agent_key.present?
    return if %w[root unresolved].include?(lineage_state) && parent_agent_key.nil?

    errors.add(:lineage_state, "must be \"known\" exactly when a parent agent is named")
  end
end
