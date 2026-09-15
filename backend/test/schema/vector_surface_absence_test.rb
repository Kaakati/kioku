# frozen_string_literal: true

require "test_helper"

# The scope decision made executable.
#
# CLAUDE.md: "Embeddings, embedding models, vector search and hybrid search are
# out of scope for this release; do not reintroduce them." The frozen contract
# repeats it: "Embeddings ... are removed from scope, not deferred and not
# conditional. No field, enum value, error code or capability in this contract
# refers to them."
#
# The `vector` extension is installed for pg_search's packaging dependency only.
# That makes it possible for someone to add a vector column later and for nobody
# to notice, because the extension being there looks like permission. These two
# tests are what turns that into a red build.
class VectorSurfaceAbsenceTest < ActiveSupport::TestCase
  test "should define no column of a pgvector type anywhere in the application schema" do
    # Arrange
    assert_canonical_schema_present

    # Act
    vector_columns = select_rows(<<~SQL).map { |row| "#{row['table_name']}.#{row['column_name']} #{row['type_name']}" }
      SELECT cls.relname AS table_name,
             att.attname AS column_name,
             typ.typname AS type_name
      FROM pg_attribute att
      JOIN pg_class cls ON cls.oid = att.attrelid
      JOIN pg_namespace ns ON ns.oid = cls.relnamespace
      JOIN pg_type typ ON typ.oid = att.atttypid
      WHERE ns.nspname = 'public'
        AND att.attnum > 0
        AND NOT att.attisdropped
        AND cls.relkind IN ('r', 'p', 'm', 'v')
        AND typ.typname IN (#{SchemaContract::VECTOR_COLUMN_TYPES.map { |t| "'#{t}'" }.join(', ')})
    SQL

    # Assert
    assert_empty vector_columns,
                 "Embeddings are out of scope. Found pgvector-typed columns: " \
                 "#{vector_columns.join(', ')}. The vector extension is installed for " \
                 "pg_search's packaging dependency and for nothing else."
  end

  test "should build no approximate nearest neighbour index over any table" do
    # Arrange
    assert_canonical_schema_present

    # Act
    indexes = select_rows(<<~SQL)
      SELECT indexname, indexdef
      FROM pg_indexes
      WHERE schemaname = 'public'
    SQL
    pattern = /USING\s+(#{SchemaContract::ANN_INDEX_METHODS.join('|')})\b/i
    ann_indexes = indexes.select { |row| row["indexdef"].match?(pattern) }

    # Assert
    assert_empty ann_indexes.map { |row| row["indexname"] },
                 "ANN indexes are out of scope. Retrieval is exact lookup, ParadeDB BM25 and " \
                 "bounded typed traversal (CLAUDE.md, contract retrieval_modes). Found: " \
                 "#{ann_indexes.map { |r| r['indexdef'] }.join('; ')}."
    refute_empty indexes,
                 "No indexes exist in the public schema at all, which makes the assertion above " \
                 "vacuous; the canonical tables must at least carry their primary keys."
  end
end
