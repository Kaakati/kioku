# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true

  config.cache_store = :memory_store, { size: 32.megabytes }

  # A pending migration must stop the request loudly; a half-migrated schema
  # produces wrong answers rather than errors.
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true

  # structure.sql is regenerated here (and only here) after a migration, using
  # the pg_dump 18 client installed in the backend image.
  config.active_record.dump_schema_after_migration = true

  # The ui container reaches the api by its Compose service name.
  config.hosts << "api"

  config.active_support.deprecation = :log
  config.active_support.disallowed_deprecation = :raise
end
