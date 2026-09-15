# frozen_string_literal: true

require "test_helper"

# Capture is the one path where a rejection must be cheap and informative: the
# host agent retires a spool entry only after a canonical receipt (plan 7.1 step
# 6), so an event the core cannot accept has to come back as a stated conflict
# rather than as an exception that leaves the spool guessing.
class EventTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @installation = seed_installation
    @project = seed_project
    @session_key = seed_session(installation_key: @installation)
    @agent_key = seed_agent(session_key: @session_key)
  end

  test "should refuse to save an event marked resolved that names no agent" do
    # Arrange — research §8: the core "never infers identity from timing or
    # process id"; attribution_state=resolved is a claim, and a claim with no
    # subject is the corruption the CHECK exists to stop.
    event = build_event(attribution_state: "resolved", agent_key: nil)

    # Act
    saved = event.save

    # Assert
    refute saved, "attribution_state 'resolved' with no agent_key must fail validation."
    assert_equal 0, row_count("events", ActiveRecord::Base.sanitize_sql_array(
      ["event_key = ?", event.event_key]
    ))
  end

  test "should refuse to save an event marked unresolved that names an agent" do
    # Arrange
    event = build_event(attribution_state: "unresolved", agent_key: @agent_key)

    # Act
    saved = event.save

    # Assert
    refute saved, "An agent_key alongside 'unresolved' hides a resolved join behind an honest label."
    assert_equal 0, row_count("events", ActiveRecord::Base.sanitize_sql_array(
      ["event_key = ?", event.event_key]
    ))
  end

  test "should refuse to save a replayed event that repeats a recorded producer sequence" do
    # Arrange — plan 7.1: "Lost acknowledgments replay safely." Safely means the
    # replay is refused by name, so the agent retires the spool entry instead of
    # writing a second copy.
    epoch = new_key("epoch")
    seed_event(installation_key: @installation, producer_key: "host-spool",
               producer_epoch: epoch, producer_sequence: 4)
    replay = build_event(producer_key: "host-spool", producer_epoch: epoch, producer_sequence: 4)

    # Act
    saved = replay.save

    # Assert
    refute saved, "A repeated (installation, producer, epoch, sequence) must fail validation."
    assert_equal 1, row_count("events", ActiveRecord::Base.sanitize_sql_array(
      ["installation_key = ? AND producer_epoch = ? AND producer_sequence = 4", @installation, epoch]
    ))
  end

  test "should refuse to save a project-scoped event that names no owner project" do
    # Arrange — plan 7.1 step 2: "unresolved project capture cannot be misfiled
    # in the global store", and invariant 11 forbids a project switch from
    # reassigning a queued event.
    event = build_event(store_kind: "project", project_key: nil)

    # Act
    saved = event.save

    # Assert
    refute saved, "An unresolved project binding is not permission to write a global event."
    assert_equal 0, row_count("events", ActiveRecord::Base.sanitize_sql_array(
      ["event_key = ?", event.event_key]
    ))
  end

  test "should leave an unresolved event unattributed rather than falling back to the session main agent" do
    # Arrange
    event_key = seed_event(installation_key: @installation, session_key: @session_key,
                           agent_key: nil, attribution_state: "unresolved")

    # Act
    event = Event.find(event_key)

    # Assert — the session is known, the agent is not, and the model must not
    # close that gap (research §8, plan invariant 9).
    assert_equal @session_key, event.session.session_key
    assert_nil event.agent
  end

  test "should reach the agent an event was actually attributed to" do
    # Arrange
    event_key = seed_event(installation_key: @installation, session_key: @session_key,
                           agent_key: @agent_key, attribution_state: "resolved",
                           origin_role: "assistant")

    # Act
    event = Event.find(event_key)

    # Assert
    assert_equal @agent_key, event.agent.agent_key
  end

  private

  def build_event(**overrides)
    Event.new({
      event_key: new_key("event"), installation_key: @installation, store_kind: "global",
      project_key: nil, producer_key: "host-spool", producer_epoch: new_key("epoch"),
      producer_sequence: 0, session_key: @session_key, agent_key: nil,
      attribution_state: "not_applicable", event_type: "user_prompt_submitted",
      origin_role: "user", observed_at: Time.current, recorded_at: Time.current
    }.merge(overrides))
  end
end
