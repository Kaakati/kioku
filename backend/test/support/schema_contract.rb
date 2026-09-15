# frozen_string_literal: true

require "securerandom"

# The storage contract that backend/test/schema/** pins down.
#
# Research Appendix A is the canonical identity/memory schema; its SQLite
# dialect is translated here, not copied (CLAUDE.md, Appendix A preface):
#
#   * `*_at_ms INTEGER`  ->  `timestamptz` columns without the suffix
#     (plan 5.1: "timestamptz for recorded/observed times").
#   * `source_anchor_json TEXT CHECK (json_valid(...))`  ->  `source_anchor jsonb`
#     (plan 5.1: "jsonb for bounded structured payloads").
#   * `installation_id`  ->  `installation_key`, matching the *_key handles the
#     frozen tool contract uses on the wire.
#   * `hash_algorithm` defaults to 'sha256' (plan 4.2: "Ruby's standard digest
#     support for SHA-256 content addressing"), not Appendix A's 'blake3'.
#   * Appendix A's `scope_kind` gains 'global' and 'project', and every owned
#     table gains `project_key`, per plan 5.2 and 1.1.
#
# Two rules the migrations must respect so these tests stay runnable:
#
#   1. Any column beyond the ones named in CanonicalSeeds must be nullable or
#      carry a default; the seeds insert only the columns listed there.
#   2. Table and column names are part of the contract. Renaming one is a schema
#      decision, and these tests are where it has to be argued.
#
# OPEN, and named as open by the contract itself ("NOT FROZEN — envelope-to-
# storage name reconciliation ... the mapping table itself must be written
# before migrations land"): the wire envelope returns `head_revision`, while
# Appendix A's storage column is `current_revision`. This suite uses the storage
# name, because `Memory#head_revision` is the association that resolves the
# pointer and a column cannot share that name. test/support/kioku_test_factories
# currently assumes the wire name as the column; one of the two has to move, and
# the choice belongs in the mapping table plan 5.2 asks for.
module SchemaContract
  # Every canonical table the persistence tests write to. Derived code/search
  # tables (plan 5.1) and the outbox are outside this set.
  CANONICAL_TABLES = %w[
    memory_evidence
    feedback
    memory_revisions
    memories
    evidence
    events
    source_objects
    scopes
    agents
    sessions
    projects
    installations
  ].freeze

  # The exact extension set the db image must end up with. `vector` is present
  # only because pg_search 0.25.9 declares pgvector as a packaging dependency;
  # a vector COLUMN, INDEX or QUERY is a scope violation, which
  # test/schema/vector_surface_absence_test.rb enforces separately.
  INSTALLED_EXTENSIONS = %w[pg_search plpgsql vector].freeze

  # What `CREATE EXTENSION pg_search CASCADE` drags into a ParadeDB image.
  # Their absence is the evidence that CASCADE was not used.
  CASCADE_DRAGGED_EXTENSIONS = %w[
    fuzzystrmatch
    pg_ivm
    postgis
    postgis_raster
    postgis_tiger_geocoder
    postgis_topology
  ].freeze

  # pgvector's column types. None of them may appear in the application schema.
  VECTOR_COLUMN_TYPES = %w[vector halfvec sparsevec].freeze

  # Approximate-nearest-neighbour index methods. None of them may be used.
  ANN_INDEX_METHODS = %w[ivfflat hnsw].freeze

  SOURCE_ANCHOR = <<~JSON.freeze
    {"schema_version":"kioku.source_anchor.v1","repository_key":null,"path":null}
  JSON

  module Helpers
    def db
      if ActiveRecord::Base.respond_to?(:lease_connection)
        ActiveRecord::Base.lease_connection
      else
        ActiveRecord::Base.connection
      end
    end

    def execute(sql)
      db.execute(sql)
    end

    def select_rows(sql)
      db.select_all(sql).to_a
    end

    def select_value(sql)
      db.select_value(sql)
    end

    def new_key(prefix)
      "#{prefix}-#{SecureRandom.uuid_v7}"
    end

    def new_content_hash
      "sha256:#{SecureRandom.hex(32)}"
    end

    def insert_row(table, **attributes)
      columns = attributes.keys.map(&:to_s)
      placeholders = Array.new(columns.length, "?").join(", ")
      statement = "INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{placeholders})"
      execute(ActiveRecord::Base.sanitize_sql_array([statement, *attributes.values]))
    end

    def row_count(table, where_sql)
      select_value("SELECT COUNT(*) FROM #{table} WHERE #{where_sql}").to_i
    end

    def truncate_canonical_tables!
      execute("TRUNCATE TABLE #{SchemaContract::CANONICAL_TABLES.join(', ')} RESTART IDENTITY CASCADE")
    end

    def base_tables
      select_rows(<<~SQL).map { |row| row["table_name"] }
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      SQL
    end

    # Guards every catalog assertion against a vacuous pass: "no vector column
    # exists" is trivially true of an empty database.
    def assert_canonical_schema_present
      missing = SchemaContract::CANONICAL_TABLES - base_tables
      assert_empty missing,
                   "The canonical schema is not loaded: #{missing.join(', ')} missing from the " \
                   "public schema. Every persistence assertion below is meaningless until the " \
                   "migrations in backend/db/migrate create these tables."
    end
  end
end
