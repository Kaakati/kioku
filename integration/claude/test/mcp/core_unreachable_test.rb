# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../kioku/contract_signing"

# "Core down | Optional hooks return without enhancement" [plan §9]; the MCP adapter
# "holds no storage authority" [contracts: envelope.transport_and_actor], so with the
# host link down it must refuse honestly rather than crash, hang or invent an answer.
#
# Every test here runs with KIOKU_SOCKET_PATH pointing at a path that cannot exist.
class McpCoreUnreachableTest < Minitest::Test
  include Kioku::TestSupport::McpCase
  include Kioku::TestSupport::ContractSigning

  SECRET_BODY = "SUPERSECRET-CANARY-BODY-9f3a"

  # The write below is signed the way a real caller signs it. Once the boundary
  # recomputes the request digest (E1), an unsigned mutation is refused with
  # kioku.invalid_request before the adapter ever tries the host link, and the case
  # asserting kioku.source_unavailable for a write would fail for a reason that has
  # nothing to do with the host being down.
  def call_tool(name, arguments)
    super(name, signed(arguments))
  end

  # --- invariants that hold whatever the wire name turns out to be -------------------

  def test_should_not_report_a_read_as_successful_when_the_host_link_is_down
    assert_not_successful search_response, "search with no reachable host"
  end

  def test_should_return_no_result_items_when_the_host_link_is_down
    envelope = Kioku::TestSupport::McpResult.envelope(search_response)

    assert_nil envelope&.dig("data", "items"),
               "an empty candidate set was rendered as an answer: #{envelope.inspect}"
  end

  # "queued means durable host enqueue" — with no agent there is no spool, so queued
  # would be as dishonest as saved [plan invariant 2; contracts: errors kioku.queued].
  def test_should_report_a_write_as_neither_saved_nor_queued_when_the_host_link_is_down
    envelope = Kioku::TestSupport::McpResult.envelope(remember_response)

    refute_equal "success", envelope&.fetch("status", nil)
    refute_equal "queued", envelope&.fetch("status", nil)
    refute_equal true, envelope&.dig("data", "saved")
  end

  # --- the named condition -----------------------------------------------------------

  def test_should_name_the_unavailable_host_link_when_a_read_cannot_reach_the_core
    assert_tool_error "kioku.source_unavailable", search_response, "read with no reachable host"
  end

  def test_should_name_the_unavailable_host_link_when_a_write_cannot_reach_the_core
    assert_tool_error "kioku.source_unavailable", remember_response, "write with no reachable host"
  end

  def test_should_mark_the_condition_retryable_when_the_host_link_is_down
    envelope = Kioku::TestSupport::McpResult.envelope(search_response)

    assert_equal true, envelope&.dig("error", "retryable"),
                 "a transient transport failure was not marked retryable"
  end

  # --- never a crash -----------------------------------------------------------------

  def test_should_keep_serving_the_tool_surface_after_a_call_fails_to_reach_the_core
    search_response

    assert server.alive?, "the adapter exited when the host link was down"
    assert_equal 6, server.tools.size
  end

  def test_should_keep_stdout_a_valid_protocol_stream_after_a_failed_call
    search_response
    server.tools

    server.raw_stdout_lines.reject { |line| line.strip.empty? }.each do |line|
      assert_equal "2.0", JSON.parse(line)["jsonrpc"], "non-protocol stdout: #{line.inspect}"
    end
  end

  # --- never a hang ------------------------------------------------------------------

  def test_should_answer_within_the_callers_deadline_when_the_host_link_is_down
    started = Kioku::TestSupport::Clock.monotonic
    call_tool("context_search",
              { "envelope" => read_envelope("deadline_ms" => 1_000), "mode" => "lexical", "query" => "outbox" })
    elapsed = Kioku::TestSupport::Clock.monotonic - started

    assert_operator elapsed, :<, 3.0, "the adapter blocked past the caller's deadline"
  end

  # --- never leaks the caller's content ---------------------------------------------

  # "message (operator-facing, content-redacted)" [contracts: response_fields.error];
  # "Diagnostic logs redact content and credentials" [plan §9].
  def test_should_redact_the_remembered_body_from_the_refusal_when_the_host_link_is_down
    rendered = JSON.generate(remember_response)

    refute_includes rendered, SECRET_BODY, "the refusal echoed the remembered content back"
  end

  def test_should_redact_the_remembered_body_from_the_diagnostic_when_the_host_link_is_down
    remember_response
    sleep 0.1

    refute_includes server.stderr_text, SECRET_BODY, "the diagnostic logged the remembered content"
  end

  private

  def search_response
    @search_response ||= call_tool(
      "context_search",
      { "envelope" => read_envelope, "mode" => "lexical", "query" => "durable outbox" }
    )
  end

  def remember_response
    @remember_response ||= call_tool(
      "context_remember",
      {
        "envelope" => mutation_envelope,
        "kind" => "decision",
        "destination" => { "store_kind" => "project", "project_key" => "kioku" },
        "title" => "Outbox replay is idempotent",
        "body" => SECRET_BODY,
        "evidence" => [{ "ref" => { "evidence_key" => "ev-1" }, "relation" => "supports" }]
      }
    )
  end
end
