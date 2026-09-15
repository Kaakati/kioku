# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/cold_boot"

# B1 — the stack does not cold-boot, and no suite can see it.
#
# compose.yml sets `POSTGRES_DB: kioku_development` on the `db` service, so the
# ParadeDB image creates the application database itself, from ITS OWN template1.
# That template1 already carries nine extensions and a `paradedb` schema, so
# db/structure.sql's unguarded `CREATE SCHEMA paradedb` (line 17) fails,
# `rails db:prepare` exits 1, `migrate` fails, and `api` — gated on
# service_completed_successfully — never starts. config/database.yml's
# `template: template0` cannot reach a database the image already made, because
# it only governs `db:create` and `db:create` never runs.
#
# backend/test/integration/provisioned_database_test.rb asks the right question —
# what is in the database DATABASE_URL names — but it can only ask it of the
# instance that happens to be running. A volume repaired by hand answers
# correctly while compose.yml still ships the defect, which is the exact state
# this repository is in right now: that suite is GREEN against the running stack
# and the stack still cannot be rebuilt. The invariant is a property of a cold
# boot, so this case performs one, from destroyed volumes, under its own Compose
# project name.
#
# It is deliberately not satisfied by "the api container is healthy". A stack
# that boots only from a volume someone fixed by hand has not been shown to boot.
class KiokuColdBootProvisioningTest < Minitest::Test
  # The exact set the migrations enable. `vector` is present only because
  # pg_search 0.25.9 declares pgvector as a packaging dependency; a vector
  # column, index or query stays out of scope.
  EXPECTED_EXTENSIONS = %w[pg_search plpgsql vector].freeze

  # The nine the ParadeDB image loads into template1. Any of them here is proof
  # the database was inherited from template1 rather than created from template0.
  TEMPLATE1_SURPLUS = %w[
    fuzzystrmatch pg_ivm pg_stat_statements
    postgis postgis_raster postgis_tiger_geocoder postgis_topology
  ].freeze

  # The four tables the one end-to-end path writes (plan §7.1). Naming these
  # rather than a table count keeps the case from passing on a migration that
  # exited zero having created nothing.
  PATH_TABLES = %w[events idempotency_receipts memories memory_revisions].freeze

  def setup
    @boot = Kioku::TestSupport::ColdBoot.result
  rescue StandardError => error
    flunk("the stack's cold boot could not be exercised: #{error.class}: #{error.message}")
  end

  def test_should_complete_the_one_shot_migration_when_the_stack_boots_from_destroyed_volumes
    assert_equal 0, @boot.migrate_status,
                 "`rails db:prepare` exited #{@boot.migrate_status} on a stack booted from empty " \
                 "volumes, so `api` — which depends on migrate with " \
                 "service_completed_successfully — never starts. This is what a new machine gets " \
                 "from `docker compose up`:\n#{tail(@boot.migrate_output)}"
  end

  def test_should_install_exactly_plpgsql_vector_and_pg_search_when_the_stack_provisions_the_database
    assert_equal EXPECTED_EXTENSIONS, @boot.extensions,
                 "the database DATABASE_URL names carries #{listed(@boot.extensions)}, and the " \
                 "surplus #{listed(@boot.extensions & TEMPLATE1_SURPLUS)} is inherited from the " \
                 "ParadeDB image's template1 — which means the IMAGE created this database " \
                 "(POSTGRES_DB names it) instead of `rails db:create` creating it from template0."
  end

  def test_should_carry_the_tables_the_end_to_end_path_writes_when_the_stack_provisions_the_database
    missing = PATH_TABLES - @boot.tables

    assert_empty missing,
                 "the database DATABASE_URL names is missing #{missing.join(', ')}; it holds " \
                 "#{@boot.tables.empty? ? 'no tables at all' : @boot.tables.join(', ')}. " \
                 "context_remember cannot reach a canonical commit against this database, so the " \
                 "end-to-end path has nothing to run on."
  end

  private

  def tail(output)
    output.to_s.lines.last(12).join
  end

  def listed(names)
    names.empty? ? "nothing" : names.join(", ")
  end
end
