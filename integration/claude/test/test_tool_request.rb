# frozen_string_literal: true

require_relative "test_helper"

class TestToolRequest < Minitest::Test
  include Kioku::TestSupport

  def build(tool, arguments)
    Kioku::ToolRequest.build(tool: tool, arguments: arguments)
  end

  def test_unknown_tool_is_unsupported
    error = assert_raises(Kioku::Error) { build("context_magic", {}) }
    assert_equal "kioku.unsupported_operation", error.code
  end

  # Embeddings, vector search and hybrid search are out of scope, so these
  # modes get the frozen unsupported_operation answer, not a generic error.
  def test_removed_retrieval_modes_map_to_unsupported_operation
    %w[semantic hybrid].each do |mode|
      error = assert_raises(Kioku::Error) do
        build("context_search", { "envelope" => read_envelope, "mode" => mode, "query" => "x" })
      end
      assert_equal "kioku.unsupported_operation", error.code
      assert_equal %w[exact lexical related], error.details["supported_modes"]
    end
  end

  def test_solutions_alias_expands_to_lexical_with_the_solutions_profile
    request = build("context_search", { "envelope" => read_envelope, "mode" => "solutions", "query" => "retry" })
    assert_equal "lexical", request.arguments["mode"]
    assert_equal "solutions", request.arguments["profile"]
  end

  def test_reads_are_not_mutations
    request = build("context_search", { "envelope" => read_envelope, "mode" => "lexical", "query" => "x" })
    refute request.mutation?
    assert_nil request.envelope["idempotency_key"]
  end

  def test_remember_is_a_mutation_and_is_sealed
    request = build("context_remember", { "envelope" => read_envelope, "kind" => "decision" })
    assert request.mutation?
    refute_nil request.envelope["request_digest"]
  end

  def test_task_get_is_a_read_and_other_ops_are_mutations
    get = build("context_task", { "envelope" => read_envelope, "op" => "get", "task_key" => "t-1" })
    refute get.mutation?
    checkpoint = build("context_task", { "envelope" => read_envelope, "op" => "checkpoint",
                                         "task_key" => "t-1", "contract_revision" => 1, "summary" => "s",
                                         "state" => "implementing" })
    assert checkpoint.mutation?
  end

  def test_unknown_task_op_is_unsupported
    error = assert_raises(Kioku::Error) { build("context_task", { "envelope" => read_envelope, "op" => "pass" }) }
    assert_equal "kioku.unsupported_operation", error.code
  end

  # The op discriminates permitted fields, not only required ones.
  def test_fields_from_another_op_are_rejected
    error = assert_raises(Kioku::Error) do
      build("context_task", { "envelope" => read_envelope, "op" => "get", "task_key" => "t-1",
                              "receipt_id" => "r-1" })
    end
    assert_equal "kioku.invalid_request", error.code
    assert_equal ["receipt_id"], error.details["rejected_fields"]
  end

  def test_deadline_defaults_and_caps_come_from_the_contract
    assert_equal 3_000, Kioku::Deadlines.default_for("context_search")
    assert_equal 10_000, Kioku::Deadlines.default_for("context_task", "assess")
    assert_equal 30_000, Kioku::Deadlines.cap_for("context_task", "close")
    assert_equal 10_000, Kioku::Deadlines.clamp("context_search", nil, 25_000)
  end

  def test_requested_deadline_is_clamped_to_the_tool_cap
    request = build("context_search", { "envelope" => read_envelope.merge("deadline_ms" => 29_000),
                                        "mode" => "lexical", "query" => "x" })
    assert_equal 10_000, request.envelope["deadline_ms"]
    assert_equal 11_500, request.socket_deadline_ms
  end

  def test_payload_carries_tool_envelope_and_arguments
    request = build("context_search", { "envelope" => read_envelope, "mode" => "exact",
                                        "keys" => [{ "kind" => "memory_key", "key" => "m-1" }] })
    payload = request.payload
    assert_equal "context_search", payload["tool"]
    assert_equal "exact", payload["arguments"]["mode"]
    refute payload["arguments"].key?("envelope")
  end
end
