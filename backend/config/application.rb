# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"

# Deliberately not required: action_mailer, action_mailbox, action_text,
# action_cable, active_storage, sprockets. Kioku's backend is an API that owns
# canonical rows and retained objects on a shared volume; none of those
# subsystems has an implemented responsibility here.

Bundler.require(*Rails.groups)

module Kioku
  class Application < Rails::Application
    config.load_defaults 8.1

    config.api_only = true

    # PostgreSQL-specific constraints, ParadeDB search indexes and functions
    # cannot round-trip through schema.rb, so the schema of record is
    # db/structure.sql (plan 5.1). This makes `db:schema:dump` shell out to
    # pg_dump, whose major version must match the server (18).
    config.active_record.schema_format = :sql

    # Application code lives under lib/context/, mapping to the Context::*
    # namespace (plan 4). `context/contracts/schemas` holds versioned JSON
    # data files read through the contracts layer, not Ruby constants.
    config.autoload_lib(ignore: %w[assets tasks context/contracts/schemas])

    # eager_load is decided per environment (config/environments/*.rb). Both the
    # api and worker services boot the same RAILS_ENV, so Zeitwerk resolves every
    # Context::* constant at startup in both processes rather than mid-request or
    # mid-job; `bin/rails zeitwerk:check` is the gate for that.

    config.active_job.queue_adapter = :sidekiq

    config.time_zone = "UTC"

    # Evidence bodies and source excerpts are stored as-is; Rails' HTML-escaping
    # of JSON string payloads would corrupt exact bytes on the wire.
    config.active_support.escape_html_entities_in_json = false

    config.generators do |g|
      g.test_framework :minitest, fixture: false
      g.helper false
      g.assets false
    end
  end
end
