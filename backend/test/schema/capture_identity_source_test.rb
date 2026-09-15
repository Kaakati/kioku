# frozen_string_literal: true

require "test_helper"

# `events.identity_source` — the recorded answer to "how do we know who produced
# this capture".
#
# Frozen contract, transport_and_actor: "The core records identity_source and
# leaves attribution_state=unresolved when the join cannot be established; it
# never infers identity from timing or process id (Research §8)." Nothing records
# it. `Context::Domain::Actor` carries the value, `Storage::MemoryWriter` drops
# it, and the one value the core produces — `:transport` — is not a member of the
# vocabulary this schema already declares for `agents.identity_source`
# (hook|telemetry|transcript|bridge|unresolved).
#
# One vocabulary, not two. The column exists so an operator can ask whether an
# attribution rests on a hook, a transcript parse or nothing but the bridge
# credential; a second spelling of the same idea on a second table makes that
# question unanswerable by a join.
class CaptureIdentitySourceTest < ActiveSupport::TestCase
  IDENTITY_SOURCES = %w[hook telemetry transcript bridge unresolved].freeze

  setup do
    assert_canonical_schema_present
    @installation = seed_installation
  end

  test "should accept every identity source the agents table already recognises" do
    # Arrange / Act
    IDENTITY_SOURCES.each { |source| insert_capture_event(identity_source: source) }

    # Assert
    assert_equal IDENTITY_SOURCES.length, row_count("events", "TRUE")
  end

  test "should refuse an identity source outside the agent identity vocabulary" do
    # Arrange — 'transport' is the value the core produces today. It names the
    # channel, not the evidence of identity, and no agents row can ever carry it,
    # so an event recorded with it could never be reconciled against one.
    assert_database_rejects(because: [PG::CheckViolation],
                            describing: "an event recorded with identity_source 'transport'") do
      insert_capture_event(identity_source: "transport")
    end
  end

  private

  def insert_capture_event(identity_source:, attribution_state: "unresolved")
    insert_row("events",
               event_key: new_key("event"),
               installation_key: @installation,
               store_kind: "global",
               producer_key: "core.remember",
               producer_epoch: new_key("epoch"),
               producer_sequence: 0,
               attribution_state: attribution_state,
               identity_source: identity_source,
               event_type: "memory_remembered",
               origin_role: "user",
               observed_at: Time.current,
               recorded_at: Time.current)
  end
end
