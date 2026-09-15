# frozen_string_literal: true

module Context
  module Domain
    # The trusted actor a use case runs as.
    #
    # Plan 6.1: the core derives actor identity from authenticated transport,
    # never from request text. `authority` is derived here from the origin role
    # and is never accepted from a caller (frozen contract, `labels.authority`).
    class Actor
      AUTHORITY_BY_ORIGIN_ROLE = {
        user: :user,
        assistant: :assistant,
        tool: :tool,
        system: :system,
        imported: :imported
      }.freeze

      attr_reader :principal_id, :origin_role, :installation_key,
                  :identity_source, :attribution_state, :agent_key

      def initialize(principal_id:, identity_source:, origin_role: nil,
                     installation_key: nil, attribution_state: :unresolved,
                     agent_key: nil)
        @principal_id = principal_id
        @identity_source = identity_source.to_sym
        @origin_role = origin_role&.to_sym
        @installation_key = installation_key
        @attribution_state = attribution_state.to_sym
        @agent_key = agent_key
        freeze
      end

      def authority
        AUTHORITY_BY_ORIGIN_ROLE[origin_role]
      end

      def user?
        authority == :user
      end
    end
  end
end
