# frozen_string_literal: true

require "test_helper"

# House standard: every foreign key gets an index. Plan 5.2 also asks for
# "indices supporting principal/scope authorization and source-dependency
# invalidation before ranking", and Appendix A ships an explicit reverse index
# (`memory_evidence_reverse`) for exactly this reason: without one, deleting a
# project or walking evidence backwards degrades to a sequential scan and the
# bounded per-request deadlines of the tool contract stop being achievable.
#
# PostgreSQL indexes the referenced side automatically (the PK or unique key it
# points at) and never the referencing side. This test checks the referencing
# side, which is the one that has to be declared.
class ForeignKeyIndexCoverageTest < ActiveSupport::TestCase
  test "should support every foreign key with an index whose leading columns are the key" do
    # Arrange
    assert_canonical_schema_present
    foreign_keys = grouped_foreign_key_columns
    refute_empty foreign_keys,
                 "No foreign keys found in the public schema; the canonical tables must declare " \
                 "them rather than relying on Active Record associations alone (plan 5.1)."
    indexes = grouped_index_key_columns

    # Act
    uncovered = foreign_keys.reject do |(table, _constraint), columns|
      indexes.fetch(table, []).any? { |keys| keys.first(columns.length) == columns }
    end

    # Assert
    assert_empty uncovered.keys,
                 "Foreign keys without a supporting index: " \
                 "#{uncovered.map { |(t, c), cols| "#{t}.#{c} (#{cols.join(', ')})" }.join('; ')}."
  end

  private

  # => { [table, constraint_name] => ["memory_key", "revision"] }
  def grouped_foreign_key_columns
    rows = select_rows(<<~SQL)
      SELECT rel.relname AS table_name,
             con.conname AS constraint_name,
             att.attname AS column_name,
             key.ord     AS position
      FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
      JOIN pg_namespace ns ON ns.oid = rel.relnamespace
      JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS key(attnum, ord) ON TRUE
      JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = key.attnum
      WHERE con.contype = 'f' AND ns.nspname = 'public'
      ORDER BY rel.relname, con.conname, key.ord
    SQL
    rows.group_by { |row| [row["table_name"], row["constraint_name"]] }
        .transform_values { |group| group.map { |row| row["column_name"] } }
  end

  # => { table => [["memory_key"], ["memory_key", "current_revision"], ...] }
  #
  # Partial indexes are excluded: an index with a WHERE clause answers only the
  # rows it covers, so it cannot stand in for a foreign key lookup.
  def grouped_index_key_columns
    rows = select_rows(<<~SQL)
      SELECT rel.relname AS table_name,
             idx.relname AS index_name,
             colno,
             pg_get_indexdef(ix.indexrelid, colno, TRUE) AS key_expression
      FROM pg_index ix
      JOIN pg_class rel ON rel.oid = ix.indrelid
      JOIN pg_class idx ON idx.oid = ix.indexrelid
      JOIN pg_namespace ns ON ns.oid = rel.relnamespace
      CROSS JOIN LATERAL generate_series(1, ix.indnkeyatts) AS colno
      WHERE ns.nspname = 'public' AND ix.indpred IS NULL
      ORDER BY rel.relname, idx.relname, colno
    SQL
    rows.group_by { |row| [row["table_name"], row["index_name"]] }
        .map { |(table, _index), group| [table, group.map { |row| row["key_expression"] }] }
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }
  end
end
