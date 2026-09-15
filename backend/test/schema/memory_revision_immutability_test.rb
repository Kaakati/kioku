# frozen_string_literal: true

require "test_helper"

# Plan invariant 4: "Revisions are immutable. Corrections append attributed
# revisions." Research Appendix A: "Old revisions remain historical; effective
# supersession can be derived from the head and explicit links without rewriting
# their original content."
#
# The contract depends on this in three places that all break silently if the
# rule lives only in Ruby: `expected_revision` optimistic concurrency
# (kioku.revision_conflict), context_feedback's requirement that a dispute names
# "an exact revision, not a head pointer", and context_fetch's `as_of_revision`
# historical read. An UPDATE that edits revision 3 in place makes every receipt
# that cited revision 3 describe text that no longer exists.
#
# PostgreSQL expresses this as a trigger, a rule or revoked privileges; the test
# accepts any of them and rejects a silent no-op, because a write that quietly
# does nothing is indistinguishable from a successful edit to the caller.
class MemoryRevisionImmutabilityTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @graph = seed_canonical_graph
    @memory_key = seed_memory_with_head(scope_key: @graph.project_scope, store_kind: "project",
                                        project_key: @graph.project,
                                        author_event_key: @graph.event,
                                        title: "Original title")
  end

  test "should reject an update to a revision that is already recorded" do
    # Arrange / Act / Assert
    assert_database_rejects(because: DatabaseRejectionAssertions::IMMUTABILITY_REFUSALS,
                            describing: "an in-place edit of a recorded revision") do
      execute(ActiveRecord::Base.sanitize_sql_array(
                ["UPDATE memory_revisions SET title = 'Rewritten' WHERE memory_key = ?", @memory_key]
              ))
    end
    assert_equal "Original title", select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT title FROM memory_revisions WHERE memory_key = ? AND revision = 1", @memory_key]
    ))
  end

  test "should reject a delete of a revision that is already recorded" do
    # Arrange / Act / Assert — privacy deletion is a separate lifecycle with
    # tombstones (plan invariant 4, §5.3), not an ordinary DELETE.
    assert_database_rejects(because: DatabaseRejectionAssertions::IMMUTABILITY_REFUSALS,
                            describing: "a delete of a recorded revision") do
      execute(ActiveRecord::Base.sanitize_sql_array(
                ["DELETE FROM memory_revisions WHERE memory_key = ?", @memory_key]
              ))
    end
    assert_equal 1, row_count("memory_revisions", ActiveRecord::Base.sanitize_sql_array(
      ["memory_key = ?", @memory_key]
    ))
  end

  test "should accept appending a new revision to a memory that already has one" do
    # Arrange / Act — append-only must mean append-ONLY, not insert-once.
    insert_revision(memory_key: @memory_key, revision: 2,
                    author_event_key: @graph.event, title: "Corrected title",
                    lifecycle: "active")

    # Assert
    titles = select_rows(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT title FROM memory_revisions WHERE memory_key = ? ORDER BY revision", @memory_key]
    )).map { |row| row["title"] }
    assert_equal ["Original title", "Corrected title"], titles
  end

  test "should reject a second revision that reuses a revision number already recorded" do
    # Arrange / Act / Assert — the composite primary key (memory_key, revision)
    # is what makes `expected_revision` a usable concurrency token.
    assert_database_rejects(because: [PG::UniqueViolation]) do
      insert_revision(memory_key: @memory_key, revision: 1,
                      author_event_key: @graph.event, title: "Concurrent writer")
    end
  end

  test "should reject a revision whose validity interval ends before it begins" do
    # Arrange — Appendix A: CHECK (valid_until_ms IS NULL OR valid_until_ms >
    # valid_from_ms). Valid time is independent of recorded time (contract
    # context_remember.valid_from / valid_until); an inverted interval makes the
    # retrieval predicate `valid_from <= now AND valid_until > now` silently
    # unsatisfiable, so the record simply disappears instead of erroring.
    now = Time.current

    # Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_revision(memory_key: @memory_key, revision: 2,
                      author_event_key: @graph.event,
                      valid_from: now, valid_until: now - 1.hour)
    end
  end

  test "should reject a revision numbered below one" do
    # Arrange / Act / Assert — Appendix A: CHECK (revision >= 1).
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_revision(memory_key: @memory_key, revision: 0,
                      author_event_key: @graph.event)
    end
  end

  test "should reject a revision whose lifecycle is outside the four-state vocabulary" do
    # Arrange — contract labels.lifecycle: proposed, active, superseded,
    # retracted. Research §5 forbids collapsing the six evidence dimensions;
    # an undefined lifecycle value reaches the delivery filter as neither.
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_revision(memory_key: @memory_key, revision: 2,
                      author_event_key: @graph.event, lifecycle: "archived")
    end
  end

  test "should reject a revision whose kind is outside the seven memory kinds" do
    # Arrange — contract context_remember.kind: decision, constraint,
    # correction, attempt, observation, procedure, task_checkpoint.
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_revision(memory_key: @memory_key, revision: 2,
                      author_event_key: @graph.event, kind: "note")
    end
  end

  test "should reject a revision that records no authoring event" do
    # Arrange — Appendix A makes author_event_key NOT NULL: research §8 requires
    # capture to enter through authenticated ingest, so a revision with no
    # originating event has no attributable authority at all.
    assert_database_rejects(because: [PG::NotNullViolation]) do
      insert_row("memory_revisions",
                 memory_key: @memory_key, revision: 2, kind: "decision",
                 title: "Unattributed", body: "body", lifecycle: "active",
                 authority: "user", author_event_key: nil, author_agent_key: nil,
                 valid_from: Time.current, valid_until: nil, recorded_at: Time.current)
    end
  end
end
