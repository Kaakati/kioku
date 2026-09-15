# frozen_string_literal: true

module Context
  module Contracts
    # The authenticated caller, as established by the transport.
    #
    # The core derives actor identity from the authenticated transport
    # principal, never from request text. Correlation hints (session, agent,
    # run) are carried but are hints: when the join cannot be established the
    # attribution state stays unresolved rather than being guessed from timing
    # or process id, and no shared "unknown agent" identity is invented.
    class Actor < Data.define(
      :principal_id,
      :origin_role,
      :transport,
      :installation_id,
      :session_key,
      :agent_key,
      :attribution_state,
      :identity_source
    )
      TRANSPORTS = %w[mcp_bridge http_ui job imported].freeze
      IDENTITY_SOURCES = %w[hook telemetry transcript bridge unresolved].freeze
      ATTRIBUTION_STATES = %w[resolved unresolved not_applicable].freeze

      def self.from_transport(principal_id:, origin_role:, transport:, installation_id:,
                              session_key: nil, agent_key: nil, identity_source: "unresolved")
        Validator.enum!(origin_role, field: "origin_role", allowed: Vocabulary.authorities)
        Validator.enum!(transport, field: "transport", allowed: TRANSPORTS)
        Validator.enum!(identity_source, field: "identity_source", allowed: IDENTITY_SOURCES)
        new(
          principal_id: principal_id, origin_role: origin_role, transport: transport,
          installation_id: installation_id, session_key: session_key, agent_key: agent_key,
          attribution_state: derive_attribution_state(agent_key: agent_key, transport: transport),
          identity_source: agent_key ? identity_source : "unresolved"
        )
      end

      # Mirrors the Appendix A constraint: resolved requires an agent key, and
      # unresolved/not_applicable require its absence. Administrative and
      # imported traffic has no agent dimension at all.
      def self.derive_attribution_state(agent_key:, transport:)
        return "resolved" if agent_key
        return "not_applicable" if %w[http_ui imported].include?(transport)

        "unresolved"
      end

      def resolved_attribution? = attribution_state == "resolved"
    end
  end
end
