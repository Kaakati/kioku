# frozen_string_literal: true

# One captured observation from a Claude Code session (research Appendix A, plan
# 5.2 "Event and evidence", plan 7.1 capture).
#
# Capture is the one path where a rejection has to be cheap and informative: the
# host agent retires a spool entry only after a canonical receipt (plan 7.1 step
# 6), so an event the core cannot accept must come back as a stated conflict
# rather than as an exception that leaves the spool guessing.
class Event < ApplicationRecord
  ATTRIBUTION_STATES = %w[resolved unresolved not_applicable].freeze
  ORIGIN_ROLES = %w[user assistant tool system imported].freeze
  STORE_KINDS = %w[global project].freeze

  belongs_to :session, foreign_key: :session_key, primary_key: :session_key,
                       optional: true
  belongs_to :agent, foreign_key: :agent_key, primary_key: :agent_key, optional: true

  validates :store_kind, inclusion: { in: STORE_KINDS }
  validates :attribution_state, inclusion: { in: ATTRIBUTION_STATES }
  validates :origin_role, inclusion: { in: ORIGIN_ROLES }
  validates :producer_sequence,
            numericality: { greater_than_or_equal_to: 0, only_integer: true },
            uniqueness: { scope: %i[installation_key producer_key producer_epoch],
                          message: "was already recorded for this producer epoch" }
  validate :attribution_state_agrees_with_agent
  validate :project_store_names_its_owner

  private

  # Research §8: the core "never infers identity from timing or process id", and
  # unresolved attribution "can remain null until resolved". 'resolved' with no
  # agent is a claim with no subject; an agent alongside 'unresolved' hides a
  # resolved join behind an honest label.
  def attribution_state_agrees_with_agent
    case attribution_state
    when "resolved"
      return if agent_key.present?

      errors.add(:agent_key, "is required when attribution_state is 'resolved'")
    when "unresolved", "not_applicable"
      return if agent_key.blank?

      errors.add(:agent_key, "must be absent when attribution_state is '#{attribution_state}'")
    end
  end

  # Plan 7.1 step 2: "unresolved project capture cannot be misfiled in the global
  # store." Plan invariant 11 forbids a project switch from reassigning a queued
  # event, so a missing binding is a refusal, never a fallback to global.
  def project_store_names_its_owner
    return unless store_kind == "project" && project_key.blank?

    errors.add(:project_key, "is required when store_kind is 'project'")
  end
end
