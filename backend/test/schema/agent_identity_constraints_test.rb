# frozen_string_literal: true

require "test_helper"

# Research Appendix A, `agents`, and its preface: "The parts that must survive
# translation are the ones easiest to drop: the CHECK constraints tying ...
# lineage_state to parent_agent_key, the partial unique index
# one_main_agent_per_session ..."
#
# Research §8: "Do not create one shared 'unknown agent' identity that falsely
# merges unrelated activity." Plan invariant 9: "Missing identity or lineage
# remains unresolved." A lineage_state of 'known' with no parent, or 'root' with
# one, is exactly the quiet corruption that turns unresolved provenance into a
# false claim of independent confirmation.
class AgentIdentityConstraintsTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @installation = seed_installation
    @session = seed_session(installation_key: @installation)
  end

  test "should reject an agent whose lineage_state is known when it names no parent" do
    # Arrange / Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_agent(session_key: @session, agent_kind: "subagent",
                 lineage_state: "known", parent_agent_key: nil)
    end
  end

  test "should reject an agent whose lineage_state is root when it names a parent" do
    # Arrange
    parent = seed_agent(session_key: @session)

    # Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_agent(session_key: @session, agent_kind: "subagent",
                 lineage_state: "root", parent_agent_key: parent)
    end
  end

  test "should reject an agent whose lineage_state is unresolved when it names a parent" do
    # Arrange
    parent = seed_agent(session_key: @session)

    # Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_agent(session_key: @session, agent_kind: "subagent",
                 lineage_state: "unresolved", parent_agent_key: parent)
    end
  end

  test "should accept an agent whose lineage_state is known and names a parent" do
    # Arrange
    parent = seed_agent(session_key: @session)

    # Act
    child = seed_agent(session_key: @session, agent_kind: "subagent",
                       lineage_state: "known", parent_agent_key: parent)

    # Assert
    assert_equal parent,
                 select_value(ActiveRecord::Base.sanitize_sql_array(
                                ["SELECT parent_agent_key FROM agents WHERE agent_key = ?", child]
                              ))
  end

  test "should reject an agent that names itself as its parent" do
    # Arrange
    agent_key = new_key("agent")

    # Act / Assert — Appendix A: CHECK (parent_agent_key IS NULL OR
    # parent_agent_key <> agent_key). PostgreSQL would otherwise accept this
    # row, because a single-row self-reference satisfies the foreign key.
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_agent(session_key: @session, agent_key: agent_key, agent_kind: "subagent",
                 lineage_state: "known", parent_agent_key: agent_key)
    end
  end

  test "should reject a second main agent in a session that already has one" do
    # Arrange
    seed_agent(session_key: @session, agent_kind: "main")

    # Act / Assert
    assert_database_rejects(because: [PG::UniqueViolation]) do
      seed_agent(session_key: @session, agent_kind: "main")
    end
  end

  test "should accept a main agent in each session because the uniqueness is per session" do
    # Arrange
    other_session = seed_session(installation_key: @installation)
    seed_agent(session_key: @session, agent_kind: "main")

    # Act
    seed_agent(session_key: other_session, agent_kind: "main")

    # Assert
    assert_equal 2, row_count("agents", "agent_kind = 'main'")
  end

  test "should accept several subagents in one session because only main is restricted" do
    # Arrange
    main = seed_agent(session_key: @session, agent_kind: "main")

    # Act
    3.times do
      seed_agent(session_key: @session, agent_kind: "subagent",
                 lineage_state: "known", parent_agent_key: main)
    end

    # Assert — the partial unique index must be partial, not a plain unique
    # index on (session_key, agent_kind).
    assert_equal 3, row_count("agents", ActiveRecord::Base.sanitize_sql_array(
      ["session_key = ? AND agent_kind = 'subagent'", @session]
    ))
  end

  test "should reject an agent kind outside the vocabulary Appendix A defines" do
    # Arrange / Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_agent(session_key: @session, agent_kind: "orchestrator")
    end
  end
end
