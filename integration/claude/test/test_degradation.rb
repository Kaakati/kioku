# frozen_string_literal: true

require "mcp"
require_relative "test_helper"
require "kioku/mcp/client"
require "kioku/mcp/response"

# What happens when the agent or the core cannot be reached. The rule is that a
# read fails visibly, a write is durably spooled and answered queued, and a hook
# returns without enhancement so normal Claude work continues.
class TestDegradation < Minitest::Test
  include Kioku::TestSupport

  def unreachable_config(home)
    Kioku::Config.new(
      home: home, file: {},
      env: { "KIOKU_HOME" => home, "KIOKU_SOCKET_PATH" => File.join(home, UNROUTABLE_SOCKET) }
    )
  end

  def test_socket_client_reports_transport_unavailable_for_a_missing_socket
    with_home do |config|
      client = Kioku::SocketClient.new(path: File.join(config.home, UNROUTABLE_SOCKET), connect_timeout_ms: 100)
      error = assert_raises(Kioku::TransportUnavailable) { client.call(op: "agent.health", deadline_ms: 200) }
      assert_equal "context-agent", error.component
      assert_equal "kioku.internal_error", error.code
    end
  end

  def test_available_is_false_when_no_socket_exists
    with_home do |config|
      client = Kioku::SocketClient.new(path: File.join(config.home, UNROUTABLE_SOCKET))
      refute client.available?
    end
  end

  def test_a_read_fails_visibly_rather_than_returning_an_empty_result
    Dir.mktmpdir("kioku-test") do |home|
      client = Kioku::Mcp::Client.new(config: unreachable_config(home), logger: silent_logger)
      request = Kioku::ToolRequest.build(
        tool: "context_search",
        arguments: { "envelope" => read_envelope, "mode" => "lexical", "query" => "redis" }
      )
      assert_raises(Kioku::TransportUnavailable) { client.call(request) }
    end
  end

  # queued means durably enqueued here. It must never be rendered as saved.
  def test_a_write_is_spooled_and_answered_queued_never_saved
    Dir.mktmpdir("kioku-test") do |home|
      config = unreachable_config(home)
      request = Kioku::ToolRequest.build(tool: "context_remember", arguments: remember_arguments)
      response = Kioku::Mcp::Client.new(config: config, logger: silent_logger).call(request)

      assert_equal "queued", response["status"]
      assert_equal "kioku.queued", response.dig("error", "code")
      assert_equal false, response.dig("data", "saved")
      assert_nil response.dig("receipt", "committed_at")
      refute_nil response.dig("data", "spool", "spool_entry_id")
      assert_equal 1, Kioku.spool_for(config).stats["pending_count"]
    end
  end

  def test_queued_is_not_rendered_as_an_mcp_error
    queued = { "status" => "queued", "error" => { "code" => "kioku.queued" } }
    refute Kioku::Mcp::Response.failure?(queued)
    refute Kioku::Mcp::Response.failure?({ "status" => "partial", "error" => { "code" => "kioku.partial_result" } })
    assert Kioku::Mcp::Response.failure?({ "status" => "conflict", "error" => { "code" => "kioku.revision_conflict" } })
    assert Kioku::Mcp::Response.failure?({ "error" => { "code" => "kioku.invalid_request" } })
    refute Kioku::Mcp::Response.failure?({ "status" => "success", "error" => nil })
  end

  def test_error_rendering_carries_the_wire_code_and_marks_is_error
    rendered = Kioku::Mcp::Response.render_error(
      Kioku::Error.new("kioku.scope_denied", "not granted"), request_id: "req-1"
    ).to_h
    assert_equal true, rendered[:isError]
    body = JSON.parse(rendered[:content].first[:text])
    assert_equal "kioku.scope_denied", body.dig("error", "code")
    assert_equal "unauthorized_scope", body["status"]
  end

  def test_hook_returns_without_enhancement_and_exits_zero_when_the_agent_is_down
    Dir.mktmpdir("kioku-test") do |home|
      stdout = StringIO.new
      status = Kioku::Hooks::Dispatcher.new(
        config: unreachable_config(home), logger: silent_logger,
        stdin: StringIO.new(JSON.generate(prompt_event(home))), stdout: stdout
      ).run

      assert_equal 0, status
      assert_equal "", stdout.string
    end
  end

  def test_hook_exits_zero_on_a_malformed_payload
    Dir.mktmpdir("kioku-test") do |home|
      stdout = StringIO.new
      status = Kioku::Hooks::Dispatcher.new(
        config: unreachable_config(home), logger: silent_logger,
        stdin: StringIO.new("not json at all"), stdout: stdout
      ).run

      assert_equal 0, status
      assert_equal "", stdout.string
    end
  end

  def test_hook_exits_zero_for_an_event_with_no_contract
    Dir.mktmpdir("kioku-test") do |home|
      stdout = StringIO.new
      status = Kioku::Hooks::Dispatcher.new(
        config: unreachable_config(home), logger: silent_logger,
        stdin: StringIO.new(JSON.generate({ "hook_event_name" => "SomeFutureEvent" })), stdout: stdout
      ).run

      assert_equal 0, status
      assert_equal "", stdout.string
    end
  end

  private

  def prompt_event(home)
    { "hook_event_name" => "UserPromptSubmit", "session_id" => "s-1", "cwd" => home, "prompt" => "why is this slow" }
  end

  def remember_arguments
    {
      "envelope" => read_envelope,
      "kind" => "decision",
      "destination" => { "store_kind" => "project", "project_key" => "demo" },
      "title" => "Bounded spool",
      "body" => "Unacknowledged records are never discarded to make room.",
      "evidence" => [{ "ref" => { "evidence_key" => "e-1" }, "relation" => "supports" }]
    }
  end
end
