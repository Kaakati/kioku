# frozen_string_literal: true

module Kioku
  module Test
    # Actors for the persistence, storage and service suites.
    #
    # These are built directly rather than through `Factories#bridge_actor` for
    # two reasons, both of which the current suite's single shared actor hides:
    #
    #   1. Idempotency keys are actor-scoped (frozen contract,
    #      envelope.idempotency_key: "string (<=128 chars, actor-scoped)"). A
    #      suite with one actor cannot express, let alone test, a scope. Every
    #      case that involves two writers names its principals here.
    #   2. `identity_source` is a recorded fact about how identity was
    #      established, and its vocabulary is the one `agents.identity_source`
    #      already declares (hook|telemetry|transcript|bridge|unresolved). The
    #      value the core produces today, `:transport`, is in neither the
    #      vocabulary nor the schema. A loopback-bridge write is `:bridge`.
    #
    # `attribution_state` defaults to :unresolved with no agent, because that is
    # what an actor authenticated by the bridge alone can honestly say: the join
    # to a Claude Code agent was not established (research §8, plan invariant 9).
    # :not_applicable is reserved for a capture that has no agent to join to.
    module PersistenceActors
      def writing_actor(principal_id:, origin_role: :user, attribution_state: :unresolved,
                        agent_key: nil, identity_source: :bridge, installation: nil)
        Context::Domain::Actor.new(
          principal_id: principal_id,
          origin_role: origin_role,
          installation_key: installation || installation_key,
          identity_source: identity_source,
          attribution_state: attribution_state,
          agent_key: agent_key
        )
      end
    end
  end
end
