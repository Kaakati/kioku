# frozen_string_literal: true

require "test_helper"

# What a capture event is allowed to claim about who produced it.
#
# `Storage::MemoryWriter` discards `Actor#attribution_state` and derives the
# recorded value from agent_key nullability instead:
#
#     attribution_state: actor.agent_key ? "resolved" : "not_applicable"
#
# "not_applicable" says there is no agent to join to. An actor that reached the
# core over the loopback bridge with no agent correlation supports a weaker
# statement: the join was not established. Research §8 is explicit that the core
# "never infers identity from timing or process id" and that attribution "can
# remain null until resolved"; plan invariant 9 calls the stronger reading false
# independent confirmation. The frozen contract says the same in one sentence:
# "The core records identity_source and leaves attribution_state=unresolved when
# the join cannot be established."
#
# That sentence also names the other half. `identity_source` is recorded, and
# today it is persisted nowhere at all — the value the core produces,
# `:transport`, is not in the vocabulary `agents.identity_source` declares
# (hook|telemetry|transcript|bridge|unresolved). A bridge-authenticated write is
# `bridge`.
class CaptureAttributionTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport
  include Kioku::Test::PersistenceActors

  setup do
    arrange_project_with_durable_evidence
    @session = seed_session(installation_key: installation_key)
    @agent = seed_agent(session_key: @session)
  end

  test "should record each actor's own attribution state rather than deriving it from agent_key" do
    # Arrange — three actors that differ only in what they can honestly claim
    # about their agent join.
    actors = {
      "unresolved" => writing_actor(principal_id: "bridge-only", attribution_state: :unresolved),
      "not_applicable" => writing_actor(principal_id: "operator", attribution_state: :not_applicable),
      "resolved" => writing_actor(principal_id: "hooked", attribution_state: :resolved,
                                  agent_key: @agent)
    }

    # Act
    recorded = actors.to_h do |state, actor|
      [state, capture_event_for(commit(actor: actor, key: "idem-#{state}")).attribution_state]
    end

    # Assert — the state travels from the actor to the row; it is not recomputed
    # from a column that only says whether a join happened to be supplied.
    assert_equal({ "unresolved" => "unresolved",
                   "not_applicable" => "not_applicable",
                   "resolved" => "resolved" }, recorded)
  end

  test "should record the identity source the actor was authenticated by" do
    # Arrange
    actor = writing_actor(principal_id: "bridge-only", identity_source: :bridge)

    # Act
    event = capture_event_for(commit(actor: actor, key: "idem-bridge"))

    # Assert — how identity was established is a recorded fact, not an inference
    # available only in memory (frozen contract, transport_and_actor).
    assert_equal "bridge", event.identity_source
  end

  test "should leave the revision unattributed to an agent when the join is unresolved" do
    # Arrange
    actor = writing_actor(principal_id: "bridge-only", attribution_state: :unresolved)

    # Act
    memory_key = commit(actor: actor, key: "idem-unattributed")

    # Assert — the honest label and the empty join belong together: an
    # unattributed revision beside an event claiming no agent exists would let a
    # later reconciliation read "nothing to resolve" and stop.
    revision = revisions_for(memory_key).first
    assert_nil revision.author_agent_key
    assert_equal "unresolved", capture_event_for(memory_key).attribution_state
  end

  private

  def commit(actor:, key:)
    result = remember_service.call(**remember_arguments(actor: actor,
                                                        envelope: mutation_envelope(idempotency_key: key)))
    assert_predicate result, :saved?, "Arrangement failed: #{result.error_code} #{result.error_details}"
    result.memory_key
  end

  def capture_event_for(memory_key)
    Event.find(revisions_for(memory_key).first.author_event_key)
  end
end
