# frozen_string_literal: true

# Canonical identity (Research Appendix A `sessions`, `agents`, `agent_runs`).
#
# Native provider IDs are scoped to their session, the main-agent key is locally
# assigned, and execution attempts are separate records. Unresolved lineage stays
# NULL rather than collapsing unrelated activity into one "unknown agent".
class CreateSessionsAndAgents < ActiveRecord::Migration[8.1]
  def change
    create_sessions
    create_agents
    add_agent_constraints
    create_agent_runs
  end

  private

  def create_sessions
    create_table :sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # Covered by the unique (installation_id, provider_session_id) index below.
      t.references :installation, null: false, type: :uuid, foreign_key: true, index: false
      t.string :session_key, null: false
      t.string :provider_session_id, null: false
      # NULL until the registered root/worktree mapping resolves a project
      # (Plan §1.2 step 3); an unresolved binding is never read as global.
      t.string :project_key
      t.bigint :context_epoch, null: false, default: 0
      t.column :started_at, :timestamptz, null: false, default: -> { "now()" }
      t.column :ended_at, :timestamptz
    end

    add_index :sessions, :session_key, unique: true
    add_index :sessions, %i[installation_id provider_session_id], unique: true,
                         name: "index_sessions_on_installation_and_provider_id"
    add_index :sessions, :project_key

    add_foreign_key :sessions, :projects, column: :project_key, primary_key: :project_key,
                                          name: "fk_sessions_project_key"

    add_check_constraint :sessions, "btrim(session_key) <> ''", name: "sessions_key_present"
    add_check_constraint :sessions, "context_epoch >= 0", name: "sessions_context_epoch_non_negative"
    add_check_constraint :sessions, "ended_at IS NULL OR ended_at >= started_at",
                         name: "sessions_end_after_start"
  end

  def create_agents
    create_table :agents, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :agent_key, null: false
      t.string :session_key, null: false
      t.string :provider_agent_id
      t.string :agent_kind, null: false
      t.string :agent_type
      t.string :parent_agent_key
      t.string :lineage_state, null: false
      t.string :identity_source, null: false
      t.column :recorded_at, :timestamptz, null: false, default: -> { "now()" }
    end

    add_index :agents, :agent_key, unique: true
    # NULL provider_agent_id values stay distinct in PostgreSQL, so several
    # unidentified agents can coexist in one session without being merged.
    # Its leftmost column also serves the session_key foreign key.
    add_index :agents, %i[session_key provider_agent_id], unique: true,
                       name: "index_agents_on_session_and_provider_id"
    add_index :agents, :parent_agent_key

    # Appendix A's partial unique index, expressed as a PostgreSQL WHERE clause.
    add_index :agents, :session_key, unique: true, where: "agent_kind = 'main'",
                       name: "one_main_agent_per_session"

    add_foreign_key :agents, :sessions, column: :session_key, primary_key: :session_key,
                                        name: "fk_agents_session_key"
    add_foreign_key :agents, :agents, column: :parent_agent_key, primary_key: :agent_key,
                                      name: "fk_agents_parent_agent_key"
  end

  def add_agent_constraints
    add_check_constraint :agents, "btrim(agent_key) <> ''", name: "agents_key_present"
    add_check_constraint :agents,
                         "agent_kind IN ('main', 'subagent', 'fork', 'teammate', 'unknown')",
                         name: "agents_agent_kind_valid"
    add_check_constraint :agents, "lineage_state IN ('root', 'known', 'unresolved')",
                         name: "agents_lineage_state_valid"
    add_check_constraint :agents,
                         "identity_source IN ('hook', 'telemetry', 'transcript', 'bridge', 'unresolved')",
                         name: "agents_identity_source_valid"
    add_check_constraint :agents, "parent_agent_key IS NULL OR parent_agent_key <> agent_key",
                         name: "agents_parent_is_not_self"

    # Lineage state and parent nullability move together: a known parent must be
    # named, and root/unresolved agents must not carry an invented one.
    add_check_constraint :agents,
                         "(lineage_state = 'known' AND parent_agent_key IS NOT NULL) " \
                         "OR (lineage_state IN ('root', 'unresolved') AND parent_agent_key IS NULL)",
                         name: "agents_lineage_state_matches_parent"
  end

  def create_agent_runs
    create_table :agent_runs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :agent_run_key, null: false
      t.string :agent_key, null: false
      t.string :state, null: false
      t.string :model_id
      t.column :started_at, :timestamptz, null: false
      t.column :ended_at, :timestamptz
    end

    add_index :agent_runs, :agent_run_key, unique: true
    add_index :agent_runs, :agent_key

    add_foreign_key :agent_runs, :agents, column: :agent_key, primary_key: :agent_key,
                                          name: "fk_agent_runs_agent_key"

    add_check_constraint :agent_runs, "btrim(agent_run_key) <> ''", name: "agent_runs_key_present"
    add_check_constraint :agent_runs,
                         "state IN ('running', 'completed', 'interrupted', 'failed', 'unknown')",
                         name: "agent_runs_state_valid"
    add_check_constraint :agent_runs, "ended_at IS NULL OR ended_at >= started_at",
                         name: "agent_runs_end_after_start"
  end
end
