# frozen_string_literal: true

require_relative "../test_helper"

# "Hook clients read bounded stdin" [research §11]; "contextctl | Bounded stdin decoding"
# [plan §3 trust-boundary table]; "Validate ... payload size" [plan §6.3].
#
# Bounded means the hook stops reading past its limit and exits, rather than buffering
# whatever a transcript, a pasted log or a runaway tool result happens to be.
class ContextctlBoundedStdinTest < Minitest::Test
  OVERSIZED_BYTES = 16 * 1024 * 1024
  CHUNK = ("x" * 64 * 1024).freeze
  HOOK_BUDGET_SECONDS = 0.9

  def oversized_hook(timeout: 5.0)
    Kioku::TestSupport::HostCommand.stream("contextctl", "hook", timeout: timeout) do |stdin|
      stdin.write(%({"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"))
      written = 0
      while written < OVERSIZED_BYTES
        stdin.write(CHUNK)
        written += CHUNK.bytesize
      end
      stdin.write(%("}))
      :consumed
    end
  end

  def result
    @result ||= oversized_hook
  end

  def test_should_stop_reading_rather_than_buffer_the_whole_payload_when_stdin_is_oversized
    assert_equal :refused, result.stdin_outcome,
                 "the hook consumed #{OVERSIZED_BYTES} bytes of stdin instead of enforcing a bound"
  end

  def test_should_exit_within_the_hook_budget_when_stdin_is_oversized
    assert result.exited?, "the hook never exited while stdin was oversized"
    assert_operator result.elapsed, :<, HOOK_BUDGET_SECONDS,
                    "the oversized hook took #{result.elapsed.round(3)}s"
  end

  def test_should_report_the_input_bound_on_stderr_when_stdin_is_oversized
    refute_empty result.stderr.strip, "an oversized payload was accepted without any diagnostic"
  end

  def test_should_emit_no_event_output_on_stdout_when_stdin_is_oversized
    assert_empty result.stdout.strip, "an oversized payload still produced event output"
  end

  # "Optional enhancement failure must allow normal Claude work to continue"
  # [plan invariant 10]: refusing an oversized payload must not block the turn.
  def test_should_not_block_the_turn_when_stdin_is_oversized
    refute_equal 2, result.exit_code, "an oversized payload blocked the user's turn"
  end

  # Non-vacuousness: an ordinary payload is read in full and is not treated as oversized.
  def test_should_accept_an_ordinary_sized_payload_without_reporting_a_bound
    payload = { "hook_event_name" => "UserPromptSubmit", "session_id" => "s",
                "prompt" => "y" * 4_096 }
    ordinary = Kioku::TestSupport::HostCommand.run("contextctl", "hook",
                                                   stdin_data: JSON.generate(payload), timeout: 5.0)

    assert_equal :consumed, ordinary.stdin_outcome, "a 4 KiB prompt was refused as oversized"
    assert_equal 0, ordinary.exit_code
  end
end
