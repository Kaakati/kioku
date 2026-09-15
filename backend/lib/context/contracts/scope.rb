# frozen_string_literal: true

module Context
  module Contracts
    # The requested scope of one tool call (plan 6.1, frozen contract
    # `request_fields.scope`). `both` is the default retrieval posture of plan
    # 1.3 — the active project plus applicable global records. A global
    # operation declares `global` explicitly; it is never reached by omitting
    # project_key.
    class Scope
      STORES = %i[project global both].freeze

      attr_reader :store, :project_key

      def initialize(store:, project_key: nil)
        @store = store.to_sym
        raise ArgumentError, "unknown scope store #{store.inspect}" unless STORES.include?(@store)

        @project_key = project_key
        freeze
      end

      def project?
        store != :global
      end

      def global?
        store != :project
      end
    end
  end
end
