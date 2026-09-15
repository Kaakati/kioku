# frozen_string_literal: true

# ParadeDB's pg_search is the lexical/BM25 retrieval implementation (plan 5.4).
#
# `vector` is enabled for exactly one reason: pg_search 0.25.9 declares pgvector
# as a hard packaging dependency, and `CREATE EXTENSION pg_search` fails without
# it. That is packaging, NOT permission. Embeddings, vector search and hybrid
# search are out of scope for this release (CLAUDE.md; the frozen contract says
# they are "removed from scope, not deferred and not conditional"). A vector
# COLUMN, INDEX or QUERY anywhere in this schema is a defect —
# test/schema/vector_surface_absence_test.rb turns one into a red build.
#
# Two rules this migration exists to hold:
#
#   1. Order. `vector` before `pg_search`, because the second fails without the
#      first.
#   2. No CASCADE. On paradedb/paradedb:0.25.9-pg18 `CREATE EXTENSION pg_search
#      CASCADE` drags in postgis, postgis_raster, postgis_topology,
#      postgis_tiger_geocoder, pg_ivm and fuzzystrmatch. None has an implemented
#      responsibility here and each enlarges what pg_dump must carry and what a
#      restore must reproduce (plan 9).
#
# The other half of the exact-extension-set rule lives in config/database.yml:
# this image's template1 already carries all nine, so every database Rails
# creates is created from template0.
class EnableSearchExtensions < ActiveRecord::Migration[8.1]
  def up
    enable_extension "vector"
    enable_extension "pg_search"
  end

  def down
    disable_extension "pg_search"
    disable_extension "vector"
  end
end
