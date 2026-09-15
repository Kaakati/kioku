# frozen_string_literal: true

require "test_helper"

# Research §8 and Appendix A: a parent key "is populated only from supported
# evidence", and "unresolved event attribution can remain null until resolved."
# Plan invariant 9: "Lineage is not independent confirmation ... Missing
# identity or lineage remains unresolved."
#
# The database CHECKs (test/schema/agent_identity_constraints_test.rb) are the
# guarantee. These tests pin the model side, because the identity resolver runs
# on the ingest path: it needs a validation failure it can record as
# attribution_state=unresolved, not a PG exception that aborts a capture
# transaction carrying other events.
class AgentTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @installation = seed_installation
    @session_key = seed_session(installation_key: @installation)
  end

  test "should refuse to save an agent whose lineage is known but names no parent" do
    # Arrange
    agent = Agent.new(agent_key: new_key("agent"), session_key: @session_key,
                      provider_agent_id: new_key("provider-agent"), agent_kind: "subagent",
                      lineage_state: "known", parent_agent_key: nil, identity_source: "hook")

    # Act
    saved = agent.save

    # Assert
    refute saved, "lineage_state 'known' asserts a resolved parent; with none it must not save."
    assert_equal 0, row_count("agents", ActiveRecord::Base.sanitize_sql_array(
      ["agent_key = ?", agent.agent_key]
    ))
  end

  test "should refuse to save an agent whose lineage is root but names a parent" do
    # Arrange
    parent = seed_agent(session_key: @session_key)
    agent = Agent.new(agent_key: new_key("agent"), session_key: @session_key,
                      provider_agent_id: new_key("provider-agent"), agent_kind: "subagent",
                      lineage_state: "root", parent_agent_key: parent, identity_source: "hook")

    # Act
    saved = agent.save

    # Assert
    refute saved, "A root agent with a parent records a lineage the state denies."
    assert_equal 0, row_count("agents", ActiveRecord::Base.sanitize_sql_array(
      ["agent_key = ?", agent.agent_key]
    ))
  end

  test "should refuse to save a second main agent in a session that already has one" do
    # Arrange — Appendix A's partial unique index one_main_agent_per_session.
    seed_agent(session_key: @session_key, agent_kind: "main")
    duplicate = Agent.new(agent_key: new_key("agent"), session_key: @session_key,
                          provider_agent_id: new_key("provider-agent"), agent_kind: "main",
                          lineage_state: "root", identity_source: "hook")

    # Act
    saved = duplicate.save

    # Assert
    refute saved, "A session has one main agent; a second is a failed identity join, not a fork."
    assert_equal 1, row_count("agents", ActiveRecord::Base.sanitize_sql_array(
      ["session_key = ? AND agent_kind = 'main'", @session_key]
    ))
  end

  test "should reach the parent and its siblings across the lineage association" do
    # Arrange
    main = seed_agent(session_key: @session_key, agent_kind: "main")
    first = seed_agent(session_key: @session_key, agent_kind: "subagent",
                       lineage_state: "known", parent_agent_key: main)
    second = seed_agent(session_key: @session_key, agent_kind: "subagent",
                        lineage_state: "known", parent_agent_key: main)
    seed_agent(session_key: @session_key, agent_kind: "subagent", lineage_state: "unresolved")

    # Act
    parent = Agent.find(first).parent

    # Assert — the unresolved agent is not adopted into the lineage just because
    # it shares a session; research §8 forbids inferring identity from context.
    assert_equal main, parent.agent_key
    assert_equal [first, second].sort, parent.children.pluck(:agent_key).sort
  end

  test "should leave an unresolved agent without a parent rather than attaching it to the session main" do
    # Arrange
    seed_agent(session_key: @session_key, agent_kind: "main")
    orphan = seed_agent(session_key: @session_key, agent_kind: "subagent",
                        lineage_state: "unresolved")

    # Act
    parent = Agent.find(orphan).parent

    # Assert — "Do not create one shared 'unknown agent' identity that falsely
    # merges unrelated activity" (Appendix A).
    assert_nil parent
  end
end
