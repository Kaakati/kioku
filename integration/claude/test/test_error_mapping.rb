# frozen_string_literal: true

require "mcp"
require_relative "test_helper"
require "kioku/mcp/validation"
require "kioku/mcp/response"

# Every rejection the MCP surface produces must carry a frozen wire name. The
# SDK's own validator answers with an untyped sentence, so Kioku validates the
# arguments itself and maps the outcome onto the contract.
class TestErrorMapping < Minitest::Test
  include Kioku::TestSupport

  def setup
    @validator = Kioku::Mcp::Validator.new
  end

  def decode(tool, arguments)
    Kioku::ToolRequest.precheck!(tool: tool, arguments: arguments)
    @validator.validate!(tool, arguments)
    Kioku::ToolRequest.build(tool: tool, arguments: arguments)
  end

  def code_for(tool, arguments)
    decode(tool, arguments)
    nil
  rescue Kioku::Error => e
    e.code
  end

  def test_a_valid_call_decodes
    request = decode("context_search", { "envelope" => read_envelope, "mode" => "lexical", "query" => "x" })
    assert_equal "context_search", request.tool
  end

  def test_schema_violations_become_invalid_request
    assert_equal "kioku.invalid_request", code_for("context_search", { "envelope" => read_envelope })
    assert_equal "kioku.invalid_request",
                 code_for("context_search", { "envelope" => read_envelope, "mode" => "lexical" })
  end

  def test_a_missing_envelope_becomes_invalid_request_not_an_untyped_error
    assert_equal "kioku.invalid_request", code_for("context_search", { "mode" => "lexical", "query" => "x" })
  end

  # A permanently removed mode is an unsupported operation, not a bad argument.
  def test_removed_modes_keep_their_own_wire_name_ahead_of_schema_validation
    %w[semantic hybrid].each do |mode|
      assert_equal "kioku.unsupported_operation",
                   code_for("context_search", { "envelope" => read_envelope, "mode" => mode, "query" => "x" })
    end
  end

  def test_an_unknown_task_op_is_unsupported_not_invalid
    assert_equal "kioku.unsupported_operation",
                 code_for("context_task", { "envelope" => read_envelope, "op" => "pass", "task_key" => "t-1" })
  end

  def test_a_known_op_missing_its_required_fields_is_invalid_request
    assert_equal "kioku.invalid_request",
                 code_for("context_task", { "envelope" => read_envelope, "op" => "close", "task_key" => "t-1" })
  end

  def test_the_violation_detail_is_reported_and_bounded
    error = assert_raises(Kioku::Error) { decode("context_remember", { "envelope" => read_envelope }) }
    assert_equal "context_remember", error.details["tool"]
    assert_includes error.details["detail"], "missing required properties"
    assert_operator error.details["detail"].bytesize, :<=, Kioku::Mcp::Validator::MAX_DETAIL_BYTES
  end

  def test_the_published_schema_still_declares_required_fields
    published = @validator.schema_for("context_search").to_h
    assert_includes published[:required], "envelope"
    assert_includes published[:required], "mode"
  end

  # The SDK guard is delegated so it cannot answer before Kioku does.
  def test_the_sdk_missing_required_guard_is_delegated
    schema = @validator.schema_for("context_search")
    assert_empty schema.missing_required_arguments({})
    refute schema.missing_required_arguments?({})
  end

  def test_scope_and_identity_failures_keep_their_own_codes
    body = { "envelope" => { "scope" => { "store" => "both" } }, "mode" => "lexical", "query" => "x" }
    assert_equal "kioku.project_binding_unresolved", code_for("context_search", body)

    identity = { "envelope" => read_envelope.merge("authority" => "user"), "mode" => "lexical", "query" => "x" }
    assert_equal "kioku.invalid_request", code_for("context_search", identity)
  end

  def test_every_mapped_error_renders_as_an_mcp_tool_error
    Kioku::WIRE_CODES.each do |code|
      next if %w[ok kioku.partial_result kioku.queued].include?(code)

      rendered = Kioku::Mcp::Response.render_error(Kioku::Error.new(code, "x")).to_h
      assert_equal true, rendered[:isError], code
      assert_equal code, JSON.parse(rendered[:content].first[:text]).dig("error", "code")
    end
  end
end
