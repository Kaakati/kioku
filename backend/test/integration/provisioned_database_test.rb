# frozen_string_literal: true

require "test_helper"
require "pg"

# B1 — the coverage hole that let a non-cold-bootable stack ship.
#
# test/schema/extension_inventory_test.rb asserts the extension inventory of the
# database Rails CONNECTED to, which in the test environment is the `_test`
# database config/database.yml derives and which Rails itself creates with
# `template: template0`. That database is not the artifact. The artifact is the
# database named by DATABASE_URL — the one `migrate` prepares and the one `api`
# and `worker` serve from — and on paradedb/paradedb:0.25.9-pg18 that database is
# created by the IMAGE, from the image's own template1, whenever POSTGRES_DB
# names it. template1 there already carries nine extensions and a `paradedb`
# schema, so:
#
#   * the inventory invariant is violated in the shipped database while the
#     suite stays green against a different one, and
#   * db/structure.sql's unguarded `CREATE SCHEMA paradedb` then fails, so
#     `rails db:prepare` exits 1, `migrate` fails, and `api` — gated on
#     service_completed_successfully — never starts at all.
#
# Both facts are properties of ONE database, so both are asserted against that
# database here. The provisioning fix is to stop the image from creating the
# application database (so `db:create` makes it from template0, as
# config/database.yml already declares) rather than to loosen the invariant.
#
# This connects out of band, with libpq, rather than through Active Record: the
# suite's connection is bound to the test database for the whole run, and
# pg_extension and information_schema are per-database catalogs.
class ProvisionedDatabaseTest < ActiveSupport::TestCase
  # The nine the ParadeDB image loads into its own template1. Any of them in the
  # application database is proof that the database was inherited from template1
  # instead of being created by Rails from template0.
  TEMPLATE1_SURPLUS = %w[
    fuzzystrmatch pg_ivm pg_stat_statements
    postgis postgis_raster postgis_tiger_geocoder postgis_topology
  ].freeze

  test "should install exactly plpgsql, vector and pg_search in the database DATABASE_URL names" do
    # Arrange
    url = application_database_url

    # Act
    installed = query(url, "SELECT extname FROM pg_extension ORDER BY extname")
               .map { |row| row["extname"] }

    # Assert
    assert_equal SchemaContract::INSTALLED_EXTENSIONS, installed,
                 "#{described(url)} carries #{installed.join(', ')}. The surplus " \
                 "#{(installed & TEMPLATE1_SURPLUS).join(', ')} is inherited from the ParadeDB " \
                 "image's template1, which means the IMAGE created this database (POSTGRES_DB " \
                 "names it) instead of `rails db:create` creating it from template0. " \
                 "config/database.yml's `template: template0` cannot reach a database the image " \
                 "already made. The connected test database is not evidence here: Rails creates " \
                 "that one itself, which is exactly why this invariant was green while the " \
                 "shipped database violated it."
  end

  test "should carry the canonical schema in the database DATABASE_URL names" do
    # Arrange
    url = application_database_url

    # Act
    present = query(url, <<~SQL).map { |row| row["table_name"] }
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    SQL
    missing = SchemaContract::CANONICAL_TABLES - present

    # Assert
    assert_empty missing,
                 "#{described(url)} is missing #{missing.join(', ')}. `migrate` runs " \
                 "`rails db:prepare` against this database; when the image created it from " \
                 "template1 the `paradedb` schema already exists, db/structure.sql's " \
                 "`CREATE SCHEMA paradedb` fails, db:prepare exits 1, and `api` never starts " \
                 "because it is gated on service_completed_successfully. An empty application " \
                 "database is what a failed cold boot looks like from inside the stack."
  end

  private

  def application_database_url
    url = ENV["DATABASE_URL"].to_s
    refute_empty url,
                 "DATABASE_URL is unset. It names the database `migrate` prepares and `api` " \
                 "serves from; without it this suite can only inspect the test database, which " \
                 "is the blind spot this case exists to close."
    url
  end

  def described(url)
    "the application database #{URI.parse(url).path.delete_prefix('/')} (DATABASE_URL)"
  rescue URI::InvalidURIError
    "the application database named by DATABASE_URL"
  end

  def query(url, sql)
    connection = PG.connect(url)
    begin
      connection.exec(sql).to_a
    ensure
      connection.close
    end
  rescue PG::Error => error
    flunk("could not connect to #{described(url)}: #{error.class}: #{error.message.lines.first}")
  end
end
