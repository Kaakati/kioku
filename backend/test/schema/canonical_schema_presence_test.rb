# frozen_string_literal: true

require "test_helper"

# Research Appendix A names the canonical identity and memory tables; plan 5.2
# extends them with projects and the global/project scope kinds. This is the
# guard the rest of the persistence suite leans on: a catalog assertion such as
# "no column has type vector" is vacuously true of an empty database, so every
# such test calls assert_canonical_schema_present first.
class CanonicalSchemaPresenceTest < ActiveSupport::TestCase
  test "should create every canonical identity and memory table when the migrations have run" do
    # Arrange
    expected = SchemaContract::CANONICAL_TABLES

    # Act
    present = base_tables

    # Assert
    assert_empty expected - present,
                 "Missing canonical tables: #{(expected - present).join(', ')}. " \
                 "Research Appendix A plus plan 5.2 require all of: #{expected.join(', ')}."
  end

  test "should store recorded and observed times as timestamptz rather than integer milliseconds" do
    # Arrange — Appendix A's *_at_ms INTEGER columns translate to timestamptz
    # (plan 5.1), and a naive `timestamp without time zone` loses the offset the
    # host spool and the container disagree on.
    assert_canonical_schema_present

    # Act
    types = select_rows(<<~SQL).to_h { |row| ["#{row['table_name']}.#{row['column_name']}", row["data_type"]] }
      SELECT table_name, column_name, data_type
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND column_name IN ('observed_at', 'recorded_at', 'valid_from', 'valid_until', 'stored_at')
    SQL

    # Assert
    %w[events.observed_at events.recorded_at memory_revisions.valid_from
       memory_revisions.recorded_at source_objects.stored_at].each do |column|
      assert_equal "timestamp with time zone", types[column],
                   "#{column} must be timestamptz; found #{types[column].inspect}."
    end
  end
end
