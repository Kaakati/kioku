# frozen_string_literal: true

# Extension baseline for the ParadeDB image (paradedb/paradedb:0.25.9-pg18).
#
# Order matters and CASCADE is forbidden: `CREATE EXTENSION pg_search CASCADE`
# drags in postgis, postgis_topology, postgis_tiger_geocoder, pg_ivm and
# fuzzystrmatch. Installing `vector` explicitly first satisfies pg_search's
# packaging dependency without any of that.
class EnableKiokuExtensions < ActiveRecord::Migration[8.1]
  def change
    enable_extension "vector"    # packaging dependency of pg_search 0.25.9 ONLY — no vector columns, indexes or queries exist in this system; embeddings are out of scope
    enable_extension "pg_search"
  end
end
