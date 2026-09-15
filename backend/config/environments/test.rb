# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false

  # Eager loading in test is the standing check that every Context::* constant
  # resolves under Zeitwerk, in the same way the api and worker processes load
  # it (plan 4).
  config.eager_load = true

  config.cache_store = :null_store

  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :rescuable

  config.active_support.deprecation = :raise
  config.active_support.disallowed_deprecation = :raise

  # Tests run against PostgreSQL (plan 4.2); never rewrite the schema of record
  # from a test run.
  config.active_record.dump_schema_after_migration = false
end
