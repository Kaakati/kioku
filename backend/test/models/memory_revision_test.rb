# frozen_string_literal: true

require "test_helper"

# Plan invariant 4 ("Revisions are immutable") is enforced in PostgreSQL by
# test/schema/memory_revision_immutability_test.rb. These tests pin the Ruby
# side of it and the evidence/feedback associations that the delivery filter
# reads, because a link attached to the wrong revision is invisible: the row is
# there, it just describes something the caller never asked about.
class MemoryRevisionTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @graph = seed_canonical_graph
    @memory_key = seed_memory_with_head(scope_key: @graph.project_scope, store_kind: "project",
                                        project_key: @graph.project,
                                        author_event_key: @graph.event,
                                        title: "Original title")
    insert_revision(memory_key: @memory_key, revision: 2, author_event_key: @graph.event,
                    title: "Corrected title")
    execute(ActiveRecord::Base.sanitize_sql_array(
              ["UPDATE memories SET current_revision = 2 WHERE memory_key = ?", @memory_key]
            ))
  end

  test "should refuse an in-place edit of a persisted revision before it reaches PostgreSQL" do
    # Arrange
    revision = MemoryRevision.find_by!(memory_key: @memory_key, revision: 1)

    # Act / Assert — the append-only trigger is the guarantee; the model refuses
    # first so a service never sends a doomed statement inside a transaction
    # that also carries the outbox row (plan 5.1).
    assert_raises(ActiveRecord::ReadOnlyRecord) { revision.update!(title: "Rewritten") }
    assert_equal "Original title", select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT title FROM memory_revisions WHERE memory_key = ? AND revision = 1", @memory_key]
    ))
  end

  test "should link both supporting and contradicting evidence to the revision it was recorded on" do
    # Arrange — contract: "Material contrary evidence is never the thing dropped
    # to fit", so a contradicting link must be as reachable as a supporting one.
    supporting = seed_evidence(scope_key: @graph.project_scope, origin_event_key: @graph.event)
    contradicting = seed_evidence(scope_key: @graph.project_scope, origin_event_key: @graph.event)
    insert_memory_evidence(memory_key: @memory_key, revision: 1,
                           evidence_key: supporting, relation: "supports")
    insert_memory_evidence(memory_key: @memory_key, revision: 1,
                           evidence_key: contradicting, relation: "contradicts")

    # Act
    linked = MemoryRevision.find_by!(memory_key: @memory_key, revision: 1)
                           .evidence.pluck(:evidence_key)

    # Assert
    assert_equal [supporting, contradicting].sort, linked.sort
  end

  test "should preserve the relation recorded on each evidence link" do
    # Arrange
    supporting = seed_evidence(scope_key: @graph.project_scope, origin_event_key: @graph.event)
    contradicting = seed_evidence(scope_key: @graph.project_scope, origin_event_key: @graph.event)
    insert_memory_evidence(memory_key: @memory_key, revision: 1,
                           evidence_key: supporting, relation: "supports")
    insert_memory_evidence(memory_key: @memory_key, revision: 1,
                           evidence_key: contradicting, relation: "contradicts")

    # Act
    relations = MemoryRevision.find_by!(memory_key: @memory_key, revision: 1)
                              .evidence_links.pluck(:evidence_key, :relation).to_h

    # Assert
    assert_equal "supports", relations[supporting]
    assert_equal "contradicts", relations[contradicting]
  end

  test "should not report evidence linked to a sibling revision as its own" do
    # Arrange — Appendix A keys memory_evidence on (memory_key, revision). A
    # link that drifted onto the head would let a correction inherit the
    # evidence that supported the statement it corrects.
    evidence_key = seed_evidence(scope_key: @graph.project_scope, origin_event_key: @graph.event)
    insert_memory_evidence(memory_key: @memory_key, revision: 1, evidence_key: evidence_key)

    # Act
    linked = MemoryRevision.find_by!(memory_key: @memory_key, revision: 2).evidence

    # Assert
    assert_empty linked
  end

  test "should report feedback recorded against the exact revision it names" do
    # Arrange — contract context_feedback.target: "an exact revision, not a head
    # pointer. A head-only reference returns kioku.invalid_request, because a
    # dispute must name what was actually disputed."
    insert_feedback(memory_key: @memory_key, revision: 1, author_event_key: @graph.event,
                    action: "dispute", disposition: "open")

    # Act
    disputed = MemoryRevision.find_by!(memory_key: @memory_key, revision: 1).feedbacks
    untouched = MemoryRevision.find_by!(memory_key: @memory_key, revision: 2).feedbacks

    # Assert
    assert_equal ["dispute"], disputed.pluck(:action)
    assert_empty untouched, "A dispute against revision 1 must not follow the memory to revision 2."
  end

  test "should reach the memory head it belongs to from any of its revisions" do
    # Arrange / Act
    revision = MemoryRevision.find_by!(memory_key: @memory_key, revision: 1)

    # Assert — the superseded revision still resolves to the memory, whose head
    # has moved past it; that is how a historical fetch labels itself.
    assert_equal @memory_key, revision.memory.memory_key
  end
end
