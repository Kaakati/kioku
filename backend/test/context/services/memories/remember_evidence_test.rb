# frozen_string_literal: true

require "test_helper"

# Frozen contract: context_remember rejects a write with kioku.evidence_required
# when no supplied evidence link is eligible, and reports evidence_rejected with
# reason `unavailable` for a reference whose bytes are not durable (invariant 3,
# Research Appendix A). Invariant 4 covers revision immutability: "Corrections
# append attributed revisions."
class RememberEvidenceTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport

  DURABLE = Kioku::Test::Factories::DURABLE_OBJECT_KEY
  MISSING = Kioku::Test::Factories::MISSING_OBJECT_KEY

  setup do
    arrange_project_with_durable_evidence
  end

  test "should reject an explicit write and persist nothing when no evidence link is supplied" do
    result = remember_service.call(**remember_arguments(evidence: []))

    assert_equal :conflict, result.status
    assert_equal "kioku.evidence_required", result.error_code
    refute_predicate result, :saved?
    assert_equal 0, memory_revision_count
    assert_equal 0, receipt_count("idem-1")
  end

  test "should reject an explicit write when every supplied evidence reference is ineligible" do
    object_store = fake_object_store(durable: [])

    result = remember_service(object_store: object_store).call(
      **remember_arguments(evidence: [{ ref: { object_key: MISSING }, relation: :supports }])
    )

    assert_equal "kioku.evidence_required", result.error_code
    assert_equal 0, memory_revision_count
  end

  test "should commit only the durable evidence link when one referenced object has no durable bytes" do
    object_store = fake_object_store(durable: [DURABLE])
    evidence = [
      { ref: { object_key: DURABLE }, relation: :supports },
      { ref: { object_key: MISSING }, relation: :contradicts }
    ]

    result = remember_service(object_store: object_store).call(**remember_arguments(evidence: evidence))

    assert_predicate result, :saved?
    assert_equal [DURABLE], result.evidence_accepted.map { |entry| entry[:ref][:object_key] }
    assert_equal [MISSING], result.evidence_rejected.map { |entry| entry[:ref][:object_key] }
    assert_equal [:unavailable], result.evidence_rejected.map { |entry| entry[:reason] }
    assert_equal 1, evidence_relations_for(memory_key: result.memory_key, revision: result.revision).size
  end

  test "should preserve a contradicting evidence relation when its object is durable" do
    evidence = [{ ref: { object_key: DURABLE }, relation: :contradicts }]

    result = remember_service.call(**remember_arguments(evidence: evidence))

    relations = evidence_relations_for(memory_key: result.memory_key, revision: result.revision)
    assert_equal ["contradicts"], relations.map { |row| row["relation"] }
  end

  test "should append a new attributed revision and leave the prior one readable when a memory is corrected" do
    create_memory(memory_key: "memory-1", revisions: 1, title: "Original", body: "Original")

    result = remember_service.call(
      **remember_arguments(memory_key: "memory-1",
                           kind: :correction,
                           title: "Corrected title",
                           body: "The lease was never the cause; the retry was not idempotent.",
                           envelope: mutation_envelope(idempotency_key: "idem-correct", expected_revision: 1))
    )

    prior, corrected = revisions_for("memory-1").to_a

    assert_equal 2, result.revision
    assert_equal 2, memory_record("memory-1").current_revision
    assert_equal "Original 1", prior.body
    assert_equal "decision", prior.kind
    assert_equal "The lease was never the cause; the retry was not idempotent.", corrected.body
    assert_equal "correction", corrected.kind
  end

  test "should attribute a correction to its own capture event rather than the prior revision's" do
    create_memory(memory_key: "memory-1", revisions: 1, title: "Original", body: "Original")

    remember_service.call(
      **remember_arguments(memory_key: "memory-1",
                           kind: :correction,
                           body: "The retry was not idempotent.",
                           envelope: mutation_envelope(idempotency_key: "idem-correct", expected_revision: 1))
    )

    prior, corrected = revisions_for("memory-1").to_a

    refute_nil corrected.author_event_key
    refute_equal prior.author_event_key, corrected.author_event_key
  end
end
