# frozen_string_literal: true

require_relative "../test_helper"

# "context-mcp | ... | stdout is reserved for MCP" [plan §3 trust-boundary table];
# "The MCP process reserves stdout for protocol messages" [research §11].
# A single leaked log line corrupts the JSON-RPC stream, so the diagnostics must exist
# and must be on stderr.
class McpStdoutPurityTest < Minitest::Test
  def teardown
    @server&.close
  end

  def start(env = {})
    @server = Kioku::TestSupport::StdioServer.new("context-mcp", env: env)
  end

  def assert_pure_protocol(server, context)
    server.raw_stdout_lines.reject { |line| line.strip.empty? }.each do |line|
      message = begin
        JSON.parse(line)
      rescue JSON::ParserError
        flunk("#{context}: non-protocol text on stdout: #{line.inspect}")
      end
      assert_equal "2.0", message["jsonrpc"], "#{context}: stdout line is not a JSON-RPC message: #{line.inspect}"
    end
  end

  def test_should_emit_the_initialize_response_as_the_very_first_stdout_line_when_the_server_starts
    server = start
    server.handshake

    first = JSON.parse(server.raw_stdout_lines.first)

    assert_equal 1, first["id"], "a banner or diagnostic preceded the first protocol message"
  end

  def test_should_keep_every_stdout_line_a_protocol_message_when_a_tool_call_fails
    server = start
    server.handshake
    server.call_tool("context_search", { "envelope" => read_envelope, "mode" => "lexical", "query" => "outbox" })

    assert_pure_protocol(server, "failing tool call")
  end

  # Non-vacuousness: the diagnostic must actually be produced, on stderr. A server that
  # simply logs nothing would pass a stdout-only assertion.
  def test_should_write_the_diagnostic_to_stderr_when_a_tool_call_cannot_reach_the_host
    server = start("KIOKU_LOG_LEVEL" => "debug")
    server.handshake
    server.call_tool("context_search", { "envelope" => read_envelope, "mode" => "lexical", "query" => "outbox" })
    sleep 0.1

    refute_empty server.stderr_text.strip, "no diagnostic was emitted on stderr for an unreachable host"
    assert_pure_protocol(server, "debug logging enabled")
  end

  def test_should_keep_stdout_pure_when_debug_logging_is_enabled_for_the_whole_session
    server = start("KIOKU_LOG_LEVEL" => "debug")
    server.handshake
    server.tools
    server.call_tool("context_task", { "envelope" => read_envelope, "op" => "get", "task_key" => "task-1" })

    assert_pure_protocol(server, "debug session")
  end

  def test_should_keep_serving_protocol_on_stdout_when_a_malformed_line_arrives_on_stdin
    server = start
    server.handshake
    server.write_raw("this is not a json-rpc frame")

    names = server.tools.map { |tool| tool["name"] }

    assert_equal 6, names.size, "the server stopped serving after malformed input"
    assert_pure_protocol(server, "after malformed stdin")
  end

  def test_should_report_malformed_stdin_on_stderr_rather_than_on_stdout
    server = start
    server.handshake
    server.write_raw("{\"jsonrpc\":\"2.0\",\"id\":")
    server.tools
    sleep 0.1

    refute_empty server.stderr_text.strip, "malformed input produced no diagnostic anywhere"
    assert_pure_protocol(server, "malformed frame")
  end
end
