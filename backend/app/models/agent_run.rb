# frozen_string_literal: true

# One execution attempt of an agent. Runs are separate from agent identity so an
# interrupted or failed attempt keeps its own outcome instead of rewriting the
# agent (Research Appendix A `agent_runs`).
class AgentRun < ApplicationRecord
  STATES = %w[running completed interrupted failed unknown].freeze

  belongs_to :agent, primary_key: :agent_key, foreign_key: :agent_key, inverse_of: :agent_runs

  validates :agent_run_key, presence: true, uniqueness: true
  validates :state, inclusion: { in: STATES }
  validates :started_at, presence: true
  validate :ended_at_not_before_started_at

  def finished?
    ended_at.present?
  end

  private

  def ended_at_not_before_started_at
    return if ended_at.nil? || started_at.nil? || ended_at >= started_at

    errors.add(:ended_at, "cannot be before started_at")
  end
end
