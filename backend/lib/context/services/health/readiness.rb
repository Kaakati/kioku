# frozen_string_literal: true

module Context
  module Services
    module Health
      # Readiness, not liveness (plan 3.1, compose health contract).
      #
      # The api service is usable only once the database answers AND the
      # canonical schema is loaded. A process that has booted but whose database
      # holds nothing but migration bookkeeping cannot serve a tool call, so
      # connectivity alone is not a ready verdict.
      #
      # The connection is a constructor collaborator so "unreachable" and
      # "schema absent" are separable without tearing down a real database.
      class Readiness
        # One canonical table stands for the schema. It is the table every
        # memory read and write reaches, so its absence means the api cannot
        # serve a request whatever else exists.
        CANONICAL_TABLE = "memories"

        UNAVAILABLE = [ActiveRecord::ActiveRecordError, PG::Error].freeze

        Result = Struct.new(:checks, keyword_init: true) do
          def ready?
            checks[:database_connectivity] == :ok && checks[:schema_presence] == :present
          end
        end

        def initialize(connection: nil)
          @connection = connection
        end

        def call
          Result.new(checks: checks)
        end

        private

        def checks
          connection.select_value("SELECT 1")
          { database_connectivity: :ok, schema_presence: schema_presence }
        rescue *UNAVAILABLE
          # Nothing is known about the schema when the connection failed, so the
          # verdict must not claim presence either way.
          { database_connectivity: :failed, schema_presence: :unknown }
        end

        def schema_presence
          connection.data_source_exists?(CANONICAL_TABLE) ? :present : :absent
        end

        def connection
          @connection ||= ActiveRecord::Base.lease_connection
        end
      end
    end
  end
end
