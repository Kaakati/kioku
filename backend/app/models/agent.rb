# frozen_string_literal: true

# A local agent identity inside a session: the main agent, a subagent, a fork or
# a teammate (research Appendix A, plan 5.2).
#
# The database holds the guarantee (see the CHECKs and the partial unique index
# in db/migrate/*_create_session_identity.rb). These validations exist because
# the identity resolver runs on the ingest path: it needs a recordable failure it
# can turn into attribution_state=unresolved, not a PG exception that aborts a
# capture transaction carrying other events.
class Agent < ApplicationRecord
  KINDS = %w[main subagent fork teammate unknown].freeze
  LINEAGE_STATES = %w[root known unresolved].freeze
  IDENTITY_SOURCES = %w[hook telemetry transcript bridge unresolved].freeze

  belongs_to :session, foreign_key: :session_key, primary_key: :session_key,
                       inverse_of: :agents

  belongs_to :parent, class_name: "Agent", foreign_key: :parent_agent_key,
                      primary_key: :agent_key, optional: true, inverse_of: :children

  has_many :children, class_name: "Agent", foreign_key: :parent_agent_key,
                      primary_key: :agent_key, inverse_of: :parent,
                      dependent: :restrict_with_exception

  validates :agent_kind, inclusion: { in: KINDS }
  validates :lineage_state, inclusion: { in: LINEAGE_STATES }
  validates :identity_source, inclusion: { in: IDENTITY_SOURCES }
  validate :lineage_state_agrees_with_parent
  validate :parent_is_another_agent
  validate :session_has_no_other_main_agent, if: -> { agent_kind == "main" }

  private

  # Research §8: a parent key "is populated only from supported evidence", and
  # missing lineage "remains unresolved". A 'known' state with no parent claims a
  # resolved join that nothing backs; a 'root' or 'unresolved' state with one
  # records a lineage the state denies. Either turns unresolved provenance into
  # plan invariant 9's false independent confirmation.
  def lineage_state_agrees_with_parent
    case lineage_state
    when "known"
      return if parent_agent_key.present?

      errors.add(:parent_agent_key, "is required when lineage_state is 'known'")
    when "root", "unresolved"
      return if parent_agent_key.blank?

      errors.add(:parent_agent_key, "must be absent when lineage_state is '#{lineage_state}'")
    end
  end

  # A single-row self-reference satisfies the foreign key, so nothing else stops
  # an agent from being recorded as its own parent.
  def parent_is_another_agent
    return if parent_agent_key.blank? || parent_agent_key != agent_key

    errors.add(:parent_agent_key, "cannot be the agent itself")
  end

  # Appendix A's one_main_agent_per_session. A second main agent is a failed
  # identity join, not a fork.
  def session_has_no_other_main_agent
    scope = Agent.where(session_key: session_key, agent_kind: "main")
    scope = scope.where.not(agent_key: agent_key) if agent_key.present?
    return unless scope.exists?

    errors.add(:agent_kind, "session already has a main agent")
  end
end
