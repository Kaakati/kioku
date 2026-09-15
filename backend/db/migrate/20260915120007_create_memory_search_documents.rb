# frozen_string_literal: true

# The derived lexical projection of current memory revisions (plan 5.1 "derived
# code/search tables", plan 5.4 "Search document lifecycle").
#
# Derived, not canonical: this table is rebuildable from memories and
# memory_revisions, and it is deliberately outside SchemaContract::CANONICAL_
# TABLES. It is published in the same transaction as the canonical change it
# projects (plan 5.4), which is what keeps an edit from leaving a stale row
# eligible.
#
# Appendix A's FTS5 virtual table and its three synchronising triggers are NOT
# translated: ParadeDB indexes ordinary PostgreSQL rows in place, so there is no
# shadow table to keep in step and no second-system sync (plan 5.4). The integer
# surrogate key survives, because pg_search needs a stable unique `key_field`.
#
# Scope filtering (store_kind, project_key) is a plain SQL predicate, not an
# indexed BM25 field: pushdown is a performance property, and authorization
# remains mandatory even when PostgreSQL executes the residual filter
# (plan 5.4).
class CreateMemorySearchDocuments < ActiveRecord::Migration[8.1]
  def up
    create_table :memory_search_documents do |t|
      t.text :memory_key, null: false
      t.bigint :revision, null: false
      t.text :store_kind, null: false
      t.text :project_key
      t.text :title, null: false
      t.text :body, null: false
    end

    # One current document per memory (Appendix A: memory_key TEXT NOT NULL
    # UNIQUE). A second row for the same memory would let a superseded revision
    # keep answering queries.
    add_index :memory_search_documents, :memory_key, unique: true
    add_index :memory_search_documents, %i[memory_key revision],
              name: "memory_search_documents_revision"
    add_index :memory_search_documents, :project_key
    add_foreign_key :memory_search_documents, :memory_revisions,
                    column: %i[memory_key revision], primary_key: %i[memory_key revision]
    add_foreign_key :memory_search_documents, :projects, column: :project_key,
                                                         primary_key: :project_key

    execute <<~SQL
      CREATE INDEX memory_search_documents_bm25
        ON memory_search_documents
        USING bm25 (id, title, body)
        WITH (key_field = 'id');
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS memory_search_documents_bm25"
    drop_table :memory_search_documents
  end
end
