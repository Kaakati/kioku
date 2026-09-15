# frozen_string_literal: true

require "test_helper"

# Research Appendix A: "Insert the memory head and its initial revision in one
# transaction; the deferred composite foreign key prevents a committed head from
# pointing to a nonexistent revision." Its preface lists "the deferred circular
# reference between memories.current_revision and memory_revisions" among the
# constraints that must survive translation to PostgreSQL.
#
# Both halves are load-bearing and they pull in opposite directions:
#   * Not deferrable -> the two-row circular insert is impossible, and the
#     implementation invents a nullable head or a second write, which breaks
#     plan 7.1 step 5 ("A short transaction commits event/revision/head ...").
#   * Not enforced   -> a committed head can name a revision that was never
#     written, and context_fetch resolves a head to nothing while reporting
#     success.
#
# This case runs WITHOUT the transactional-test wrapper on purpose: a deferred
# constraint is checked at COMMIT, so a test that never commits can never
# observe it.
class MemoryHeadDeferredReferenceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    assert_canonical_schema_present
    truncate_canonical_tables!
    @graph = seed_canonical_graph
  end

  teardown do
    truncate_canonical_tables!
  end

  test "should commit a memory head written before the revision it points at when both land in one transaction" do
    # Arrange
    memory_key = new_key("memory")

    # Act — the head is inserted first, naming a revision that does not exist
    # yet. Only a DEFERRABLE INITIALLY DEFERRED foreign key survives this.
    ActiveRecord::Base.transaction do
      insert_memory_head(memory_key: memory_key, scope_key: @graph.global_scope,
                         store_kind: "global", project_key: nil, current_revision: 1)
      insert_revision(memory_key: memory_key, revision: 1,
                      author_event_key: @graph.event, title: "Prefer small functions")
    end

    # Assert — after commit the head resolves to its revision.
    title = select_value(ActiveRecord::Base.sanitize_sql_array([<<~SQL, memory_key]))
      SELECT r.title
      FROM memories m
      JOIN memory_revisions r
        ON r.memory_key = m.memory_key AND r.revision = m.current_revision
      WHERE m.memory_key = ?
    SQL
    assert_equal "Prefer small functions", title
  end

  test "should refuse at commit a memory head whose revision is never written" do
    # Arrange
    memory_key = new_key("memory")

    # Act / Assert — deferring the check is not waiving it.
    assert_database_rejects(because: [PG::ForeignKeyViolation],
                            describing: "a head committed without its revision") do
      insert_memory_head(memory_key: memory_key, scope_key: @graph.global_scope,
                         store_kind: "global", project_key: nil, current_revision: 1)
    end
    assert_equal 0, row_count("memories", ActiveRecord::Base.sanitize_sql_array(
      ["memory_key = ?", memory_key]
    ))
  end

  test "should refuse to advance a memory head to a revision that was never appended" do
    # Arrange
    memory_key = seed_memory_with_head(scope_key: @graph.global_scope, store_kind: "global",
                                       author_event_key: @graph.event)

    # Act / Assert — plan 7.1 appends the revision and advances the head in one
    # transaction; advancing alone must not commit.
    assert_database_rejects(because: [PG::ForeignKeyViolation]) do
      execute(ActiveRecord::Base.sanitize_sql_array(
                ["UPDATE memories SET current_revision = 2 WHERE memory_key = ?", memory_key]
              ))
    end
    assert_equal 1, select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT current_revision FROM memories WHERE memory_key = ?", memory_key]
    )).to_i
  end

  test "should commit an appended revision and its advanced head together" do
    # Arrange
    memory_key = seed_memory_with_head(scope_key: @graph.global_scope, store_kind: "global",
                                       author_event_key: @graph.event, title: "First")

    # Act
    ActiveRecord::Base.transaction do
      insert_revision(memory_key: memory_key, revision: 2,
                      author_event_key: @graph.event, title: "Second")
      execute(ActiveRecord::Base.sanitize_sql_array(
                ["UPDATE memories SET current_revision = 2 WHERE memory_key = ?", memory_key]
              ))
    end

    # Assert — the superseded revision is still there; Appendix A: "Old
    # revisions remain historical."
    assert_equal 2, row_count("memory_revisions", ActiveRecord::Base.sanitize_sql_array(
      ["memory_key = ?", memory_key]
    ))
    assert_equal "Second", select_value(ActiveRecord::Base.sanitize_sql_array([<<~SQL, memory_key]))
      SELECT r.title
      FROM memories m
      JOIN memory_revisions r
        ON r.memory_key = m.memory_key AND r.revision = m.current_revision
      WHERE m.memory_key = ?
    SQL
  end
end
