# frozen_string_literal: true

# Readiness probe for the api and worker containers.
#
# An unconditional 200 would let Compose mark the api healthy while the database
# is unreachable or the schema has not been migrated, and the ui would then show
# empty results instead of a disconnection. Readiness therefore proves two
# things on every call: a live connection, and a schema at the expected version.
class HealthController < ActionController::API
  def show
    checks = { database: database_check, schema: schema_check }
    ready = checks.each_value.all? { |check| check[:status] == "ok" }

    render json: {
      status: ready ? "ok" : "unavailable",
      service: "kioku-api",
      checks: checks,
      time: Time.now.utc.iso8601
    }, status: ready ? :ok : :service_unavailable
  end

  private

  # Cheapest possible proof that a connection is checked out and the server
  # answers, rather than that a pool entry exists.
  def database_check
    value = ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.select_value("SELECT 1")
    end

    return failure("unexpected_select_result") unless value.to_i == 1

    { status: "ok" }
  rescue StandardError => e
    failure(e.class.name)
  end

  # Schema presence: the migration table exists and no migration is pending.
  # The one-shot `migrate` service runs before api and worker start, so a
  # pending migration here means the boot order broke or a deploy is half
  # applied; either way the api is not ready to serve canonical reads.
  def schema_check
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      return failure("schema_migrations_missing") unless connection.data_source_exists?("schema_migrations")
    end

    context = ActiveRecord::Base.connection_pool.migration_context
    return failure("pending_migrations").merge(current_version: context.current_version) if context.needs_migration?

    { status: "ok", current_version: context.current_version }
  rescue StandardError => e
    failure(e.class.name)
  end

  # Only the failure class or reason is reported. Driver messages can carry the
  # connection string, and an operator-facing body is still content- and
  # credential-redacted.
  def failure(reason)
    { status: "unavailable", reason: reason }
  end
end
