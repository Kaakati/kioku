# frozen_string_literal: true

require "test_helper"

# Invariant 1 and Research 5: authority, lifecycle, availability, applicability,
# claim support and coverage stay separate and are never collapsed into one
# verified boolean or a confidence float. Frozen contract: "A BM25 score is a
# relevance score and is returned in a separate field; it is never claim
# support"; `continuation` is reads-only and null on mutations, while `coverage`
# and `generation_vector` are required on both.
class SerializationLabelsTest < ActiveSupport::TestCase
  COLLAPSED_FIELD_NAMES = %w[confidence verified score trust truthiness].freeze

  test "should render applicability claim support and coverage as three separate item fields" do
    payload = Context::Serialization::Item.call(item: search_item)

    assert_equal "historical", payload["applicability"]
    assert_equal "unassessed", payload.dig("claim_support", "value")
    assert_equal "partial", payload.dig("coverage", "state")
    refute_equal payload["applicability"], payload["claim_support"]
    refute_equal payload["applicability"], payload["coverage"]
  end

  test "should refuse to reduce claim support to a boolean or a float when rendering an item" do
    payload = Context::Serialization::Item.call(item: search_item)

    assert_kind_of Hash, payload["claim_support"]
    assert_kind_of Hash, payload["coverage"]
    COLLAPSED_FIELD_NAMES.each do |name|
      refute payload.key?(name), "item payload collapsed the evidence dimensions into #{name.inspect}"
    end
  end

  test "should keep the BM25 relevance score out of claim support when the item was never assessed" do
    payload = Context::Serialization::Item.call(item: search_item)

    assert_in_delta 12.75, payload.dig("relevance", "bm25_score"), 0.001
    assert_equal "unassessed", payload.dig("claim_support", "value")
    assert_nil payload.dig("claim_support", "evaluator")
  end

  test "should render each observed generation as its own field when serializing a read response" do
    payload = Context::Serialization::Response.call(**read_response_arguments)

    vector = payload["generation_vector"]
    assert_equal 41, vector["canonical_generation"]
    assert_equal 7, vector["policy_generation"]
    assert_equal 12, vector["global_generation"]
    assert_equal 918, vector["index_generation"]
    assert_equal 3, vector["deletion_epoch"]
    assert_equal "disconnected", vector["host_link_state"]
  end

  test "should render a continuation handle separate from coverage when a read was truncated" do
    payload = Context::Serialization::Response.call(**read_response_arguments)

    assert_equal "partial", payload.dig("coverage", "state")
    assert_equal "cursor-opaque-1", payload.dig("continuation", "cursor")
    assert_equal true, payload.dig("continuation", "reauthorized_on_use")
  end

  test "should render a null continuation while still rendering coverage when serializing a mutation" do
    payload = Context::Serialization::Response.call(**mutation_response_arguments)

    assert payload.key?("continuation"), "mutation response omitted the continuation field entirely"
    assert_nil payload["continuation"]
    assert_equal "complete_for_declared_set", payload.dig("coverage", "state")
    refute_nil payload["generation_vector"]
  end

  private

  def search_item
    {
      handle: "memory:alpha:memory-1",
      subject_kind: :memory,
      store_kind: :project,
      owner: { project_key: "alpha", origin_project_key: nil },
      title: "Invoice retry fails under concurrent workers",
      revision: 3,
      head_revision: 3,
      authority: :assistant,
      lifecycle: :active,
      availability: :available,
      applicability: :historical,
      claim_support: { value: :unassessed, evaluator: nil, attributed_at: nil, rationale_ref: nil },
      coverage: {
        state: :partial,
        counts: { considered: 40, returned: 10, truncated_at: 10 },
        gaps: [{ kind: :host_disconnected, detail: "control connection down", count: 1 }],
        completeness_label: "known_within_indexed_coverage"
      },
      relevance: { bm25_score: 12.75, rank: 1, tiebreak_key: "memory-1" },
      dispute: { has_open_dispute: false, count: 0, objection_handles: [] },
      override_status: :none
    }
  end

  def generation_vector
    {
      canonical_generation: 41, policy_generation: 7, global_generation: 12,
      index_generation: 918, source_epoch: 55, deletion_epoch: 3,
      host_link_state: :disconnected, observed_at: "2026-09-15T00:00:00Z"
    }
  end

  def read_response_arguments
    {
      request_id: "0199aa00-0000-7000-8000-000000000001",
      status: :partial,
      data: { items: [search_item] },
      error: { code: "kioku.partial_result", message: "traversal budget exhausted",
               retryable: false, retry_after_ms: nil, details: {} },
      coverage: { state: :partial, counts: { considered: 40, returned: 10, truncated_at: 10 },
                  gaps: [], completeness_label: "known_within_indexed_coverage" },
      generation_vector: generation_vector,
      continuation: { cursor: "cursor-opaque-1", expires_at: "2026-09-15T00:05:00Z",
                      reauthorized_on_use: true, reset_required_reason: nil },
      limits: { deadline_at: "2026-09-15T00:00:05Z", elapsed_ms: 12, candidate_limit: 40,
                returned: 10, truncated: true },
      warnings: [],
      server_time: "2026-09-15T00:00:00Z"
    }
  end

  def mutation_response_arguments
    read_response_arguments.merge(
      status: :success,
      data: { memory_key: "memory-1", revision: 2, head_revision: 2, saved: true },
      error: nil,
      continuation: nil,
      coverage: { state: :complete_for_declared_set, counts: { considered: 1, returned: 1, truncated_at: nil },
                  gaps: [], completeness_label: "known_within_indexed_coverage" }
    )
  end
end
