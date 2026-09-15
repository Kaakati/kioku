# frozen_string_literal: true

require "mcp"
require_relative "test_helper"

class TestSchemas < Minitest::Test
  include Kioku::TestSupport

  def schema(tool)
    ::MCP::Tool::InputSchema.new(Kioku::Schemas.input_schema(tool))
  end

  def valid?(tool, arguments)
    schema(tool).validate_arguments(arguments)
    true
  rescue ::MCP::Tool::InputSchema::ValidationError
    false
  end

  def test_exactly_six_tools
    assert_equal 6, Kioku::TOOLS.length
    assert_equal %w[context_feedback context_fetch context_related context_remember
                    context_search context_task], Kioku::TOOLS.sort
  end

  def test_every_tool_compiles_as_an_mcp_input_schema
    Kioku::TOOLS.each do |tool|
      compiled = schema(tool).to_h
      assert_equal "object", compiled[:type], tool
      refute_empty Kioku::Schemas.description(tool)
    end
  end

  def test_search_requires_a_query_for_lexical_mode
    assert valid?("context_search", { "envelope" => read_envelope, "mode" => "lexical", "query" => "redis" })
    refute valid?("context_search", { "envelope" => read_envelope, "mode" => "lexical" })
  end

  def test_search_requires_keys_for_exact_mode
    keys = [{ "kind" => "memory_key", "key" => "m-1" }]
    assert valid?("context_search", { "envelope" => read_envelope, "mode" => "exact", "keys" => keys })
    refute valid?("context_search", { "envelope" => read_envelope, "mode" => "exact" })
  end

  def test_search_rejects_removed_modes_at_the_schema
    refute valid?("context_search", { "envelope" => read_envelope, "mode" => "semantic", "query" => "x" })
    refute valid?("context_search", { "envelope" => read_envelope, "mode" => "hybrid", "query" => "x" })
  end

  def test_related_requires_typed_edges_so_no_untyped_walk_is_possible
    seeds = [{ "kind" => "symbol_key", "key" => "Foo#bar" }]
    base = { "envelope" => read_envelope, "seeds" => seeds, "direction" => "out" }
    refute valid?("context_related", base)
    assert valid?("context_related", base.merge("edge_kinds" => ["MAY_CALL"]))
    refute valid?("context_related", base.merge("edge_kinds" => ["ANYTHING"]))
  end

  def test_related_caps_hops_at_two
    seeds = [{ "kind" => "path", "key" => "app/models/user.rb" }]
    base = { "envelope" => read_envelope, "seeds" => seeds, "direction" => "both", "edge_kinds" => ["DEFINES"] }
    assert valid?("context_related", base.merge("max_hops" => 2))
    refute valid?("context_related", base.merge("max_hops" => 3))
  end

  def test_remember_requires_at_least_one_evidence_link
    body = remember_body
    assert valid?("context_remember", body)
    refute valid?("context_remember", body.merge("evidence" => []))
  end

  def test_global_remember_requires_applicability
    global = remember_body.merge(
      "destination" => { "store_kind" => "global", "category" => "coding_style" },
      "envelope" => { "scope" => { "store" => "global" } }
    )
    refute valid?("context_remember", global)
    assert valid?("context_remember", global.merge("applicability" => { "conditions" => "ruby services" }))
  end

  def test_feedback_requires_an_exact_revision_not_a_head
    base = { "envelope" => read_envelope, "action" => "dispute", "reason" => "contradicted by the migration" }
    assert valid?("context_feedback", base.merge("target" => { "memory_key" => "m-1", "revision" => 3 }))
    refute valid?("context_feedback", base.merge("target" => { "memory_key" => "m-1" }))
  end

  def test_task_schema_discriminates_required_fields_per_op
    refute valid?("context_task", { "envelope" => read_envelope, "op" => "close", "task_key" => "t-1" })
    assert valid?("context_task", close_body)
  end

  def test_task_get_needs_only_a_task_key
    assert valid?("context_task", { "envelope" => read_envelope, "op" => "get", "task_key" => "t-1" })
    refute valid?("context_task", { "envelope" => read_envelope, "op" => "get" })
  end

  # completed_in_scope is not a checkpoint state; only close moves a task there.
  def test_checkpoint_cannot_complete_a_task
    base = { "envelope" => read_envelope, "op" => "checkpoint", "task_key" => "t-1",
             "contract_revision" => 4, "summary" => "halfway" }
    assert valid?("context_task", base.merge("state" => "implementing"))
    refute valid?("context_task", base.merge("state" => "completed_in_scope"))
  end

  def test_task_has_no_pass_operation
    refute_includes Kioku::Schemas::Task::OPS, "pass"
    assert_equal 8, Kioku::Schemas::Task::OPS.length
    refute valid?("context_task", { "envelope" => read_envelope, "op" => "pass", "task_key" => "t-1" })
  end

  def test_plan_check_requires_the_full_check_identity
    base = { "envelope" => read_envelope, "op" => "plan_check", "task_key" => "t-1",
             "contract_revision" => 1, "criterion_key" => "c-1", "check_kind" => "test" }
    refute valid?("context_task", base)
    assert valid?("context_task", base.merge(
      "expected_snapshot_ref" => "snap-1", "expected_environment_fingerprint" => "env-1",
      "verifier_digest" => "sha256:abc", "minimum_input_assurance" => "immutable_snapshot",
      "definition" => { "version" => 1 }
    ))
  end

  private

  def remember_body
    {
      "envelope" => read_envelope,
      "kind" => "decision",
      "destination" => { "store_kind" => "project", "project_key" => "demo" },
      "title" => "Use Sidekiq for indexing",
      "body" => "Indexing runs in workers, never in the write transaction.",
      "evidence" => [{ "ref" => { "evidence_key" => "e-1" }, "relation" => "supports" }]
    }
  end

  def close_body
    {
      "envelope" => read_envelope, "op" => "close", "task_key" => "t-1",
      "expected_contract_revision" => 4, "receipt_id" => "r-9",
      "expected_heads" => { "contract" => 4, "claims" => 12 }
    }
  end
end
