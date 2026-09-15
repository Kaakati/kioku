# frozen_string_literal: true

require "test_helper"

# Research Appendix A, `events`, and its preface, which names the two
# constraints here as ones "easiest to drop": the CHECK tying attribution_state
# to agent_key nullability, and the
# (installation_id, producer_key, producer_epoch, producer_sequence)
# deduplication key.
#
# Why they are load-bearing. Research §8: unresolved attribution "can remain
# null until resolved" — an event marked `resolved` with no agent is a claim of
# established identity that nothing backs, and plan invariant 9 turns that into
# false independent confirmation. The dedup key is what makes host spool replay
# safe (plan 7.1 step 6: "Lost acknowledgments replay safely"); without it a
# reconnect writes the same capture twice and every count over it is wrong.
class EventCaptureConstraintsTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @installation = seed_installation
    @session = seed_session(installation_key: @installation)
    @agent = seed_agent(session_key: @session)
  end

  test "should reject an event whose attribution_state is resolved when it names no agent" do
    # Arrange / Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_event(installation_key: @installation, session_key: @session,
                 agent_key: nil, attribution_state: "resolved")
    end
  end

  test "should reject an event whose attribution_state is unresolved when it names an agent" do
    # Arrange / Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_event(installation_key: @installation, session_key: @session,
                 agent_key: @agent, attribution_state: "unresolved")
    end
  end

  test "should reject an event whose attribution_state is not_applicable when it names an agent" do
    # Arrange / Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_event(installation_key: @installation, session_key: @session,
                 agent_key: @agent, attribution_state: "not_applicable")
    end
  end

  test "should accept an event whose attribution_state is resolved and names an agent" do
    # Arrange / Act
    event = seed_event(installation_key: @installation, session_key: @session,
                       agent_key: @agent, attribution_state: "resolved",
                       origin_role: "assistant")

    # Assert
    assert_equal @agent, select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT agent_key FROM events WHERE event_key = ?", event]
    ))
  end

  test "should reject a replayed event that repeats a producer sequence already recorded" do
    # Arrange — the host spool replays with immutable producer keys (plan 5.1).
    epoch = new_key("epoch")
    seed_event(installation_key: @installation, producer_key: "host-spool",
               producer_epoch: epoch, producer_sequence: 7)

    # Act / Assert — a different event_key must not buy a second copy.
    assert_database_rejects(because: [PG::UniqueViolation]) do
      seed_event(installation_key: @installation, producer_key: "host-spool",
                 producer_epoch: epoch, producer_sequence: 7)
    end
  end

  test "should accept the same producer sequence under a new producer epoch" do
    # Arrange — a reconnect mints a new epoch; its sequence restarts (research §8).
    seed_event(installation_key: @installation, producer_key: "host-spool",
               producer_epoch: "epoch-a", producer_sequence: 0)

    # Act
    seed_event(installation_key: @installation, producer_key: "host-spool",
               producer_epoch: "epoch-b", producer_sequence: 0)

    # Assert
    assert_equal 2, row_count("events", ActiveRecord::Base.sanitize_sql_array(
      ["installation_key = ? AND producer_sequence = 0", @installation]
    ))
  end

  test "should reject a negative producer sequence" do
    # Arrange / Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_event(installation_key: @installation, producer_sequence: -1)
    end
  end

  test "should reject an origin_role outside the authority vocabulary" do
    # Arrange — contract labels.authority: "Derived by the core from origin_role
    # and transport, never accepted from the caller." A role outside the five
    # would produce an authority label with no defined meaning.
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_event(installation_key: @installation, origin_role: "subagent")
    end
  end

  test "should reject a project-scoped event that names no owner project" do
    # Arrange — plan 5.2: "Tasks and project events require a project owner."
    # Plan 7.1 step 2: "unresolved project capture cannot be misfiled in the
    # global store", and invariant 11 forbids reassigning a queued event's owner.
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_event(installation_key: @installation, store_kind: "project", project_key: nil)
    end
  end
end
