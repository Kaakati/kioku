# frozen_string_literal: true

# `events.identity_source` — the recorded answer to "how do we know who produced
# this capture".
#
# Frozen contract, transport_and_actor: "The core records identity_source and
# leaves attribution_state=unresolved when the join cannot be established; it
# never infers identity from timing or process id (Research §8)." The value was
# carried on Context::Domain::Actor and persisted nowhere, so the first half of
# that sentence had no storage at all.
#
# One vocabulary, not two: the five values are exactly the ones
# `agents.identity_source` already declares (migration 20260915120003). The
# column exists so an operator can ask whether an attribution rests on a hook, a
# transcript parse or nothing but the bridge credential, and a second spelling of
# the same idea on a second table would make that question unanswerable by a
# join. In particular `transport` is refused: it names the channel, not the
# evidence of identity, and no agents row can ever carry it.
#
# The default is `unresolved` rather than a guess — that is the vocabulary's own
# word for "the join was not established" — so a producer that records nothing
# claims nothing.
class RecordCaptureIdentitySource < ActiveRecord::Migration[8.1]
  IDENTITY_SOURCES = %w[hook telemetry transcript bridge unresolved].freeze

  def change
    add_column :events, :identity_source, :text, null: false, default: "unresolved"
    add_check_constraint :events,
                         "identity_source IN (#{quoted(IDENTITY_SOURCES)})",
                         name: "events_identity_source_vocabulary"
  end

  private

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end
end
