# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false

  # Both the api and the worker boot this environment, so every Context::*
  # constant is resolved at startup in both processes.
  config.eager_load = true

  config.consider_all_requests_local = false

  config.cache_store = :memory_store, { size: 64.megabytes }

  # Containers log to stdout; Compose owns collection and rotation.
  config.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.log_tags = [:request_id]

  # The api is published on 127.0.0.1 only and terminates no TLS itself.
  config.force_ssl = false
  config.assume_ssl = false

  # The one-shot `migrate` service runs here. structure.sql is a committed
  # source file, not a build artifact: a container must never rewrite it.
  config.active_record.dump_schema_after_migration = false

  # Loopback Host/Origin enforcement lives in Api::V1::BaseController so there is
  # a single allowlist; Rails' host authorization is not configured here as a
  # second, divergent copy of it.
end
