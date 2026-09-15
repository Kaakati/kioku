# frozen_string_literal: true

require_relative "../test_helper"

# Argument validation happens at the MCP adapter, before any core round-trip, so a
# malformed call is refused by its frozen wire name whether or not the core is running
# [plan §4.1 "Use explicit conflict/validation errors mapped at the HTTP/MCP boundary"].
class McpToolValidationTest < Minitest::Test
  include Kioku::TestSupport::McpCase

  # "query: string (1..1024 chars) — required when mode=lexical" [contracts: tools context_search].
  def test_should_refuse_a_lexical_search_when_no_query_is_supplied
    response = call_tool("context_search", { "envelope" => read_envelope, "mode" => "lexical" })

    assert_tool_error "kioku.invalid_request", response, "lexical search without a query"
  end

  def test_should_refuse_an_exact_search_when_no_keys_are_supplied
    response = call_tool("context_search", { "envelope" => read_envelope, "mode" => "exact" })

    assert_tool_error "kioku.invalid_request", response, "exact search without keys"
  end

  def test_should_refuse_a_related_search_when_no_seeds_are_supplied
    response = call_tool("context_search",
                         { "envelope" => read_envelope, "mode" => "related", "edge_kinds" => ["DEFINES"] })

    assert_tool_error "kioku.invalid_request", response, "related search without seeds"
  end

  def test_should_refuse_a_related_search_when_no_edge_kinds_are_supplied
    response = call_tool("context_search",
                         { "envelope" => read_envelope, "mode" => "related",
                           "seeds" => [{ "kind" => "symbol_key", "key" => "Context::Services" }] })

    assert_tool_error "kioku.invalid_request", response, "related search without edge kinds"
  end

  # "semantic and hybrid are not accepted values and return kioku.unsupported_operation"
  # [contracts: tools context_search; errors kioku.unsupported_operation].
  def test_should_refuse_a_search_when_the_mode_is_semantic
    response = call_tool("context_search",
                         { "envelope" => read_envelope, "mode" => "semantic", "query" => "outbox" })

    assert_tool_error "kioku.unsupported_operation", response, "mode=semantic"
  end

  def test_should_refuse_a_search_when_the_mode_is_hybrid
    response = call_tool("context_search",
                         { "envelope" => read_envelope, "mode" => "hybrid", "query" => "outbox" })

    assert_tool_error "kioku.unsupported_operation", response, "mode=hybrid"
  end

  # "handles: array<TypedHandle> (1..50)" [contracts: tools context_fetch].
  def test_should_refuse_a_fetch_when_the_handle_batch_is_empty
    response = call_tool("context_fetch", { "envelope" => read_envelope, "handles" => [] })

    assert_tool_error "kioku.invalid_request", response, "fetch with an empty batch"
  end

  def test_should_refuse_a_fetch_when_the_handle_batch_exceeds_fifty
    handles = Array.new(51) { |index| { "kind" => "evidence", "key" => "ev-#{index}", "revision" => nil } }
    response = call_tool("context_fetch", { "envelope" => read_envelope, "handles" => handles })

    assert_tool_error "kioku.invalid_request", response, "fetch with 51 handles"
  end

  # "Covers ... hops > 2" [contracts: errors kioku.unsupported_operation].
  def test_should_refuse_a_traversal_when_more_than_two_hops_are_requested
    response = call_tool("context_related", related_arguments("max_hops" => 3))

    assert_tool_error "kioku.unsupported_operation", response, "three-hop traversal"
  end

  # "an unvalidated name returns kioku.unsupported_operation" [contracts: tools context_related].
  def test_should_refuse_a_traversal_when_an_edge_kind_is_outside_the_validated_vocabulary
    response = call_tool("context_related", related_arguments("edge_kinds" => ["CALLS_EVERYTHING"]))

    assert_tool_error "kioku.unsupported_operation", response, "unvalidated edge kind"
  end

  # Non-vacuousness: a validated edge kind must not be refused as unsupported.
  def test_should_not_refuse_a_traversal_as_unsupported_when_the_edge_kind_is_in_the_vocabulary
    response = call_tool("context_related", related_arguments("edge_kinds" => %w[MAY_CALL]))

    refute_tool_error "kioku.unsupported_operation", response, "validated edge kind MAY_CALL"
  end

  # "rejects the write with kioku.evidence_required if none is eligible"
  # [contracts: tools context_remember; errors kioku.evidence_required].
  def test_should_refuse_a_memory_write_when_it_carries_no_evidence_link
    response = call_tool("context_remember", remember_arguments("evidence" => []))

    assert_tool_error "kioku.evidence_required", response, "remember without evidence"
  end

  # "A global record without applicability conditions is refused" [contracts: tools context_remember].
  def test_should_refuse_a_global_memory_write_when_it_declares_no_applicability_conditions
    arguments = remember_arguments(
      "destination" => { "store_kind" => "global", "category" => "coding_style" }
    )
    arguments["envelope"] = mutation_envelope("scope" => { "store" => "global" })

    assert_tool_error "kioku.invalid_request", call_tool("context_remember", arguments),
                      "global write without applicability"
  end

  # "An absent or ambiguous project binding returns kioku.project_binding_unresolved; it
  # is never read as permission to write globally" [contracts: tools context_remember].
  def test_should_refuse_a_project_memory_write_when_the_destination_names_no_project
    arguments = remember_arguments("destination" => { "store_kind" => "project" })

    assert_tool_error "kioku.project_binding_unresolved", call_tool("context_remember", arguments),
                      "project write without a project key"
  end

  def test_should_refuse_a_memory_write_when_the_title_is_blank
    response = call_tool("context_remember", remember_arguments("title" => "   "))

    assert_tool_error "kioku.invalid_request", response, "remember with a blank title"
  end

  # Mutations carry an actor-scoped idempotency key and request digest [plan §6.1].
  def test_should_refuse_a_memory_write_when_the_envelope_carries_no_idempotency_key
    arguments = remember_arguments
    arguments["envelope"] = read_envelope

    assert_tool_error "kioku.invalid_request", call_tool("context_remember", arguments),
                      "mutation with a read envelope"
  end

  # "A head-only reference returns kioku.invalid_request, because a dispute must name
  # what was actually disputed" [contracts: tools context_feedback].
  def test_should_refuse_feedback_when_the_target_names_a_head_instead_of_an_exact_revision
    arguments = {
      "envelope" => mutation_envelope,
      "target" => { "memory_key" => "mem-1" },
      "action" => "dispute",
      "reason" => "The cited benchmark was run on a different schema."
    }

    assert_tool_error "kioku.invalid_request", call_tool("context_feedback", arguments),
                      "feedback against a head pointer"
  end

  def test_should_refuse_feedback_when_the_reason_is_blank
    arguments = {
      "envelope" => mutation_envelope,
      "target" => { "memory_key" => "mem-1", "revision" => 4 },
      "action" => "dispute",
      "reason" => ""
    }

    assert_tool_error "kioku.invalid_request", call_tool("context_feedback", arguments),
                      "feedback with a blank reason"
  end

  # Negative control: a well-formed read must not be refused as malformed. With no host
  # agent reachable it fails for a transport reason, never for schema validation.
  def test_should_not_refuse_a_well_formed_lexical_search_as_an_invalid_request
    response = call_tool("context_search",
                         { "envelope" => read_envelope, "mode" => "lexical", "query" => "durable outbox" })

    refute_tool_error "kioku.invalid_request", response, "well-formed lexical search"
  end

  private

  def related_arguments(overrides = {})
    {
      "envelope" => read_envelope,
      "seeds" => [{ "kind" => "symbol_key", "key" => "Context::Services::Memories::Remember" }],
      "edge_kinds" => %w[REFERENCES],
      "direction" => "both"
    }.merge(overrides)
  end

  def remember_arguments(overrides = {})
    {
      "envelope" => mutation_envelope,
      "kind" => "decision",
      "destination" => { "store_kind" => "project", "project_key" => "kioku" },
      "title" => "Pin rails-paradedb",
      "body" => "Pin the gem so the BM25 surface stays reproducible.",
      "evidence" => [{ "ref" => { "evidence_key" => "ev-1" }, "relation" => "supports" }]
    }.merge(overrides)
  end
end
