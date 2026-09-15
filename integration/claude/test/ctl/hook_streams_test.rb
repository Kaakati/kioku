# frozen_string_literal: true

require_relative "../test_helper"

# "contextctl | Bounded stdin decoding, event dispatch ... | stdout is event-specific
# output; diagnostics use stderr" [plan §3 trust-boundary table];
# "Hook clients read bounded stdin and reserve stdout for valid event-specific output;
# diagnostics use stderr" [research §11].
class ContextctlHookStreamsTest < Minitest::Test
  # Log-level prefixes and Ruby backtrace frames: text that belongs on stderr only.
  DIAGNOSTIC_TEXT = /^\s*(DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\b|\.rb:\d+:in /

  def hook(payload, env: {})
    Kioku::TestSupport::HostCommand.run("contextctl", "hook",
                                        stdin_data: JSON.generate(payload), env: env, timeout: 5.0)
  end

  def prompt_event(overrides = {})
    {
      "hook_event_name" => "UserPromptSubmit",
      "session_id" => "session-abc",
      "cwd" => Dir.pwd,
      "prompt" => "where did we decide to put the outbox?"
    }.merge(overrides)
  end

  def test_should_emit_only_parseable_event_output_on_stdout_when_the_agent_is_unreachable
    output = hook(prompt_event).stdout.strip
    parsed = output.empty? ? {} : parse_or_flag(output)

    assert_kind_of Hash, parsed,
                   "stdout carried text that is not one event-output object: #{output[0, 200].inspect}"
  end

  def test_should_keep_diagnostics_off_stdout_when_the_agent_is_unreachable
    result = hook(prompt_event)

    refute_match DIAGNOSTIC_TEXT, result.stdout, "a diagnostic leaked into the hook's stdout"
  end

  def parse_or_flag(text)
    JSON.parse(text)
  rescue JSON::ParserError
    :unparseable
  end

  # Non-vacuousness: the condition must be reported somewhere, and that somewhere is stderr.
  def test_should_report_the_unreachable_agent_on_stderr_when_the_hook_cannot_connect
    result = hook(prompt_event)

    refute_empty result.stderr.strip, "an unreachable agent produced no diagnostic on any stream"
  end

  def test_should_report_malformed_stdin_on_stderr_when_the_payload_is_not_json
    result = Kioku::TestSupport::HostCommand.run("contextctl", "hook",
                                                 stdin_data: "{not json at all", timeout: 5.0)

    refute_empty result.stderr.strip, "malformed hook input produced no diagnostic"
  end

  def test_should_emit_no_event_output_on_stdout_when_the_payload_is_not_json
    result = Kioku::TestSupport::HostCommand.run("contextctl", "hook",
                                                 stdin_data: "{not json at all", timeout: 5.0)

    assert_empty result.stdout.strip, "malformed input still produced event output"
  end

  # "Optional enhancement failure must allow normal Claude work to continue"
  # [plan invariant 10]. Exit status 2 is the blocking status in the hook contract.
  def test_should_exit_zero_when_the_payload_is_not_json
    result = Kioku::TestSupport::HostCommand.run("contextctl", "hook",
                                                 stdin_data: "{not json at all", timeout: 5.0)

    assert result.exited?, "the hook did not exit on malformed input"
    assert_equal 0, result.exit_code
  end

  def test_should_never_exit_with_the_blocking_status_when_the_agent_is_unreachable
    result = hook(prompt_event)

    refute_equal 2, result.exit_code, "a transport failure blocked the user's turn"
  end

  def test_should_emit_no_event_output_on_stdout_when_the_event_name_is_absent
    payload = prompt_event
    payload.delete("hook_event_name")
    result = hook(payload)

    assert_empty result.stdout.strip, "an undispatchable event still produced event output"
    refute_empty result.stderr.strip
  end

  def test_should_exit_zero_when_the_event_name_is_not_a_supported_event
    result = hook(prompt_event("hook_event_name" => "SomeFutureEvent"))

    assert_equal 0, result.exit_code, "an unknown event broke the user's session"
    refute_empty result.stderr.strip, "an unknown event was silently ignored"
  end
end
