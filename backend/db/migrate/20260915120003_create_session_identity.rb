# frozen_string_literal: true

# Sessions and agents: local identity for the Claude Code processes whose
# activity is captured (research Appendix A, plan 5.2 "Session and agent").
#
# The constraints here are the load-bearing part. Research §8: "SQL cannot
# establish that an asserted native ID genuinely came from Claude. Do not create
# one shared 'unknown agent' identity that falsely merges unrelated activity."
# Plan invariant 9: "Lineage is not independent confirmation ... Missing identity
# or lineage remains unresolved." A row claiming lineage_state='known' with no
# parent, or 'root' with one, is that corruption written down as fact.
class CreateSessionIdentity < ActiveRecord::Migration[8.1]
  AGENT_KINDS = %w[main subagent fork teammate unknown].freeze
  LINEAGE_STATES = %w[root known unresolved].freeze
  IDENTITY_SOURCES = %w[hook telemetry transcript bridge unresolved].freeze

  def change
    create_sessions
    create_agents
    add_agent_check_constraints
  end

  private

  def create_sessions
    create_table :sessions, id: :text, primary_key: :session_key do |t|
      t.text :installation_key, null: false
      t.text :provider_session_id, null: false
    end

    # Also the supporting index for the installation_key foreign key: its
    # leading column is the referencing column.
    add_index :sessions, %i[installation_key provider_session_id], unique: true,
                                                                   name: "sessions_provider_identity_unique"
    add_foreign_key :sessions, :installations, column: :installation_key,
                                               primary_key: :installation_key
  end

  def create_agents
    create_table :agents, id: :text, primary_key: :agent_key do |t|
      t.text :session_key, null: false
      t.text :provider_agent_id
      t.text :agent_kind, null: false
      t.text :agent_type
      t.text :parent_agent_key
      t.text :lineage_state, null: false
      t.text :identity_source, null: false
    end

    add_index :agents, %i[session_key provider_agent_id], unique: true,
                                                          name: "agents_provider_identity_unique"
    add_index :agents, :parent_agent_key
    # Appendix A's one_main_agent_per_session. Partial on purpose: a session has
    # many subagents and exactly one main agent, so a second main row is a failed
    # identity join rather than a fork.
    add_index :agents, :session_key, unique: true, where: "agent_kind = 'main'",
                                     name: "one_main_agent_per_session"

    add_foreign_key :agents, :sessions, column: :session_key, primary_key: :session_key
    add_foreign_key :agents, :agents, column: :parent_agent_key, primary_key: :agent_key
  end

  def add_agent_check_constraints
    add_check_constraint :agents, "agent_kind IN (#{quoted(AGENT_KINDS)})",
                         name: "agents_kind_vocabulary"
    add_check_constraint :agents, "lineage_state IN (#{quoted(LINEAGE_STATES)})",
                         name: "agents_lineage_state_vocabulary"
    add_check_constraint :agents, "identity_source IN (#{quoted(IDENTITY_SOURCES)})",
                         name: "agents_identity_source_vocabulary"
    # A single-row self-reference satisfies the foreign key, so PostgreSQL would
    # otherwise accept an agent that is its own parent.
    add_check_constraint :agents,
                         "parent_agent_key IS NULL OR parent_agent_key <> agent_key",
                         name: "agents_parent_is_not_self"
    add_check_constraint :agents, <<~SQL.squish, name: "agents_lineage_matches_parent"
      (lineage_state = 'known' AND parent_agent_key IS NOT NULL)
      OR (lineage_state IN ('root', 'unresolved') AND parent_agent_key IS NULL)
    SQL
  end

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end
end
