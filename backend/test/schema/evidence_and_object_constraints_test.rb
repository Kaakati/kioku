# frozen_string_literal: true

require "test_helper"

# Research Appendix A, `source_objects` and `evidence`.
#
# `evidence` CHECK (origin_event_key IS NOT NULL OR object_key IS NOT NULL) is
# what stops an evidence row from being a handle to nothing. Plan invariant 3:
# "Required object bytes must be durably stored before an available evidence
# reference commits." The contract's kioku.evidence_required exists because
# "The core enforces at least one appropriate evidence link before the
# memory-save transaction commits" — an evidence row with neither anchor would
# satisfy that count while proving nothing.
#
# `source_objects` availability is the physical object-store state ('available'
# or 'purged', plan §5.3 purge), which is a different field from the per-item
# availability LABEL the tool contract returns (available|redacted|missing|
# expired). Collapsing the two would let a purged object be rendered as merely
# redacted, and vice versa.
class EvidenceAndObjectConstraintsTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @graph = seed_canonical_graph
  end

  test "should reject evidence that anchors to neither an origin event nor a retained object" do
    # Arrange / Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_evidence(scope_key: @graph.project_scope, origin_event_key: nil, object_key: nil)
    end
  end

  test "should accept evidence anchored to an origin event alone" do
    # Arrange / Act
    evidence_key = seed_evidence(scope_key: @graph.project_scope,
                                 origin_event_key: @graph.event, object_key: nil)

    # Assert
    assert_equal @graph.event, select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT origin_event_key FROM evidence WHERE evidence_key = ?", evidence_key]
    ))
  end

  test "should accept evidence anchored to a retained object alone" do
    # Arrange
    object_key = seed_source_object

    # Act
    evidence_key = seed_evidence(scope_key: @graph.project_scope,
                                 origin_event_key: nil, object_key: object_key)

    # Assert
    assert_equal object_key, select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT object_key FROM evidence WHERE evidence_key = ?", evidence_key]
    ))
  end

  test "should reject evidence that points at an object which was never stored" do
    # Arrange — plan invariant 5: "An object ID, content hash, agent ID or graph
    # edge grants no access by itself"; the row must at least exist.
    assert_database_rejects(because: [PG::ForeignKeyViolation]) do
      seed_evidence(scope_key: @graph.project_scope, object_key: new_key("object"))
    end
  end

  test "should reject a source object whose byte length is negative" do
    # Arrange / Act / Assert — Appendix A: CHECK (byte_length >= 0). The fetch
    # contract reports truncated.total_bytes from this column; a negative value
    # makes every budget comparison against it wrong.
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_source_object(byte_length: -1)
    end
  end

  test "should accept a source object of zero bytes" do
    # Arrange / Act — an empty captured file is a real observation, not an error.
    object_key = seed_source_object(byte_length: 0)

    # Assert
    assert_equal 0, select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT byte_length FROM source_objects WHERE object_key = ?", object_key]
    )).to_i
  end

  test "should reject a source object availability outside the object-store states" do
    # Arrange — 'redacted' is a per-reference delivery label, not an object-store
    # state; storing it here would erase the difference between bytes that were
    # purged from disk and bytes that are withheld from one caller.
    assert_database_rejects(because: [PG::CheckViolation]) do
      seed_source_object(availability: "redacted")
    end
  end

  test "should accept a source object marked purged" do
    # Arrange / Act — plan 5.3: "Purge unreferenced physical objects after
    # checking remaining authorized retention references." The tombstone row
    # survives the bytes, so replay cannot resurrect them.
    object_key = seed_source_object(availability: "purged")

    # Assert
    assert_equal "purged", select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT availability FROM source_objects WHERE object_key = ?", object_key]
    ))
  end

  test "should reject a second source object that reuses a content hash already stored" do
    # Arrange — Appendix A: content_hash UNIQUE. Plan 5.3: "Content addressing
    # permits byte deduplication"; two rows for the same bytes would break the
    # reference accounting that decides when a purge is safe.
    content_hash = new_content_hash
    seed_source_object(content_hash: content_hash)

    # Act / Assert
    assert_database_rejects(because: [PG::UniqueViolation]) do
      seed_source_object(content_hash: content_hash)
    end
  end

  test "should reject an evidence link whose relation is outside supports, contradicts and context" do
    # Arrange — contract context_remember.evidence[].relation. Research §5 and
    # the partial-result rule ("Material contrary evidence is never the thing
    # dropped to fit") both depend on contradicting links staying distinguishable.
    memory_key = seed_memory_with_head(scope_key: @graph.project_scope, store_kind: "project",
                                       project_key: @graph.project,
                                       author_event_key: @graph.event)
    evidence_key = seed_evidence(scope_key: @graph.project_scope, origin_event_key: @graph.event)

    # Act / Assert
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_memory_evidence(memory_key: memory_key, revision: 1,
                             evidence_key: evidence_key, relation: "related")
    end
  end

  test "should reject an evidence link to a revision that does not exist" do
    # Arrange — Appendix A ties memory_evidence to (memory_key, revision), not
    # to the memory head, so a link cannot drift onto a later revision.
    memory_key = seed_memory_with_head(scope_key: @graph.project_scope, store_kind: "project",
                                       project_key: @graph.project,
                                       author_event_key: @graph.event)
    evidence_key = seed_evidence(scope_key: @graph.project_scope, origin_event_key: @graph.event)

    # Act / Assert
    assert_database_rejects(because: [PG::ForeignKeyViolation]) do
      insert_memory_evidence(memory_key: memory_key, revision: 2, evidence_key: evidence_key)
    end
  end
end
