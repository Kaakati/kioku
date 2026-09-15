# frozen_string_literal: true

require "test_helper"

# The derived search document must carry the lifecycle of the revision it
# projects (plan 5.4: the projection is published in the same transaction as the
# canonical change, so that an edit cannot leave a stale row eligible).
#
# `Storage::MemoryWriter#publish_search_document` copies title, body, store_kind
# and project_key and stops there. Lifecycle never reaches the projection, which
# is why `Queries::Search::Lexical` cannot gate on it and why a retracted or
# superseded head stays fully retrievable by BM25. The gate and the projection
# are one fix: a gate with nothing to read is a comment.
class MemoryWriterProjectionTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport
  include Kioku::Test::PersistenceActors

  setup do
    arrange_project_with_durable_evidence
  end

  test "should publish the search document with the lifecycle of the revision it projects" do
    # Arrange — an assistant-authored global record is recorded as proposed
    # (plan 1.3), so the projected lifecycle differs from the 'active' default
    # and cannot be produced by a hard-coded value.
    actor = writing_actor(principal_id: "assistant-1", origin_role: :assistant)

    # Act
    result = remember_service.call(**remember_arguments(
      actor: actor,
      envelope: mutation_envelope(idempotency_key: "idem-global"),
      destination: { store_kind: :global, category: :engineering_decision },
      applicability: { conditions: ["ruby services with background workers"] }
    ))

    # Assert
    assert_predicate result, :saved?, "Arrangement failed: #{result.error_code} #{result.error_details}"
    assert_equal :proposed, result.lifecycle
    assert_equal "proposed", MemorySearchDocument.find_by(memory_key: result.memory_key).lifecycle
  end

  test "should publish the search document with the lifecycle of the head after an append" do
    # Arrange — a project record committed by a user actor is active, and the
    # appended revision is what the projection has to describe (plan 5.4: one
    # current document per memory).
    actor = writing_actor(principal_id: "actor-a")
    first = remember_service.call(**remember_arguments(actor: actor))

    # Act
    appended = remember_service.call(**remember_arguments(
      actor: actor, memory_key: first.memory_key,
      envelope: mutation_envelope(idempotency_key: "idem-2", expected_revision: 1),
      title: "Invoice retry is now bounded",
      body: "The lease is held for the whole retry window, so the second worker waits."
    ))

    # Assert
    document = MemorySearchDocument.find_by(memory_key: first.memory_key)
    assert_equal appended.revision, document.revision
    assert_equal "active", document.lifecycle
  end
end
