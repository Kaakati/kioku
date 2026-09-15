# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

# The loopback bridge credential is read from the environment by the API
# boundary (compose contract: KIOKU_BRIDGE_TOKEN). Pin it before Rails boots so
# every request test authenticates against a known value instead of whatever the
# container happens to carry.
ENV["KIOKU_BRIDGE_TOKEN"] = "test-bridge-token"

require_relative "../config/environment"

unless Rails.env.test?
  abort("test_helper.rb booted #{Rails.env}; refusing to run the suite against a non-test database.")
end

# db/structure.sql is the schema of record (plan 5.1). Until the first migration
# has produced one there is nothing for maintain_test_schema! to load, and its
# failure would replace every test result with a single boot error. Individual
# tests then fail on their own terms instead: a missing table surfaces as an
# assertion that names the table, which is what makes a red run diagnostic.
ActiveRecord.maintain_test_schema = false unless Rails.root.join("db/structure.sql").exist?

require "active_record/tasks/database_tasks"

# The test database is derived from DATABASE_URL by config/database.yml and may
# not exist yet on a first run inside the compose network. This has to happen
# before rails/test_help, which reflects every eager-loaded model against the
# database as it loads.
begin
  ActiveRecord::Base.connection_pool.with_connection(&:verify!)
rescue ActiveRecord::NoDatabaseError
  ActiveRecord::Tasks::DatabaseTasks.create(ActiveRecord::Base.connection_db_config)
end

require "rails/test_help"
require "securerandom"
require "digest"

# Rails' `active_support/testing/autorun` loads Minitest itself rather than
# `minitest/autorun`, so `minitest/mock` — which defines Object#stub — never
# gets required. The health controller case substitutes the readiness service
# with `Readiness.stub(:new, ...)`, so pull it in explicitly.
require "minitest/mock"

# test/ is deliberately outside the Zeitwerk autoload paths: everything below is
# a test artifact, not an application constant. Plain requires keep it that way.
Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |file| require file }

module ActiveSupport
  class TestCase
    # Tests run against PostgreSQL (plan 4.2). Transactional tests keep each
    # case isolated; nothing here may fall back to SQLite.
    self.use_transactional_tests = true

    # Single worker on purpose. test/schema/** asserts on database-wide catalogs
    # (pg_extension, pg_index, information_schema) and one case runs without a
    # wrapping transaction, so parallel worker databases would make the result
    # depend on scheduling rather than on the schema.
    parallelize(workers: 1)

    include Kioku::Test::Doubles
    include Kioku::Test::Factories

    # Persistence suite (test/schema/**, test/models/**).
    include SchemaContract::Helpers
    include SchemaContract::Seeds
    include DatabaseRejectionAssertions
  end
end

module ActionDispatch
  class IntegrationTest
    include Kioku::Test::ApiProbe
  end
end
