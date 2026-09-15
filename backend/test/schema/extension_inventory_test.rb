# frozen_string_literal: true

require "test_helper"

# The db service runs paradedb/paradedb:0.25.9-pg18. pg_search 0.25.9 declares
# pgvector as a hard packaging dependency, so `CREATE EXTENSION pg_search` fails
# unless `vector` is installed first — packaging only, never a licence to add a
# vector column (see vector_surface_absence_test.rb).
#
# Two ways the extension set gets polluted, and this image exhibits both:
#
#   1. `CREATE EXTENSION pg_search CASCADE` pulls in postgis, postgis_topology,
#      postgis_tiger_geocoder, pg_ivm and fuzzystrmatch.
#   2. VERIFIED on this image: template1 already carries all nine extensions
#      (fuzzystrmatch, pg_ivm, pg_search, pg_stat_statements, plpgsql, postgis,
#      postgis_tiger_geocoder, postgis_topology, vector), so a plain
#      CREATE DATABASE inherits every one of them no matter how the migration
#      is written. `CREATE DATABASE ... TEMPLATE template0` plus explicit
#      `CREATE EXTENSION vector` then `CREATE EXTENSION pg_search` yields
#      exactly the three this test requires — confirmed by running both.
#
# None of the extras has an implemented responsibility here, and each one
# enlarges what a pg_dump must carry and what a restore must reproduce (plan
# §9 backup and restore). Making the set exact is the point; whether the excess
# arrived by CASCADE or by template inheritance, the fix belongs in the schema
# definition, not in a later cleanup.
class ExtensionInventoryTest < ActiveSupport::TestCase
  test "should install exactly plpgsql, vector and pg_search and nothing else" do
    # Arrange
    assert_canonical_schema_present

    # Act
    installed = select_rows("SELECT extname FROM pg_extension ORDER BY extname")
                .map { |row| row["extname"] }

    # Assert
    assert_equal SchemaContract::INSTALLED_EXTENSIONS, installed,
                 "The installed extension set must be exactly " \
                 "#{SchemaContract::INSTALLED_EXTENSIONS.join(', ')}. Found: #{installed.join(', ')}. " \
                 "On paradedb:0.25.9-pg18 the surplus is inherited from template1, so the database " \
                 "has to be created with TEMPLATE template0 (config/database.yml `template:`) and " \
                 "the migration must enable vector then pg_search explicitly, without CASCADE."
  end

  test "should not install the extensions that CREATE EXTENSION pg_search CASCADE would drag in" do
    # Arrange
    assert_canonical_schema_present

    # Act
    installed = select_rows("SELECT extname FROM pg_extension").map { |row| row["extname"] }
    dragged = installed & SchemaContract::CASCADE_DRAGGED_EXTENSIONS

    # Assert
    assert_empty dragged,
                 "#{dragged.join(', ')} are present. On paradedb:0.25.9-pg18 these arrive either " \
                 "through `CREATE EXTENSION pg_search CASCADE` or by inheritance from template1; " \
                 "verified: a database created with TEMPLATE template0 carries none of them."
  end

  test "should expose the pg_search bm25 index access method the lexical retrieval route depends on" do
    # Arrange — plan 5.4 makes ParadeDB BM25 the only ranked retrieval mode.
    # A `vector` extension present without a usable pg_search would satisfy the
    # inventory test above while leaving retrieval unimplementable.
    assert_canonical_schema_present

    # Act
    methods = select_rows("SELECT amname FROM pg_am").map { |row| row["amname"] }

    # Assert
    assert_includes methods, "bm25",
                    "pg_search must be installed in this database, not merely available in the " \
                    "image: the bm25 access method is what `CREATE INDEX ... USING bm25` needs."
  end
end
