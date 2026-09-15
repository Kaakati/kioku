# frozen_string_literal: true

require_relative "../test_helper"

# "Hooks perform bounded work ... Optional enhancement failure must allow normal Claude
# work to continue" [plan invariant 10]; "Core down | Optional hooks return without
# enhancement" [plan §9]; "The one-second hook timeout is an outer guard; the CLI
# enforces the shorter operation deadline internally" [research Appendix B].
#
# A hook that hangs breaks the user's Claude session, so the budget is measured.
class ContextctlHookDegradationTest < Minitest::Test
  # The frozen event list [research §11 / Appendix B].
  SUPPORTED_EVENTS = %w[
    SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure
    SubagentStart SubagentStop PreCompact PostCompact Stop SessionEnd
  ].freeze

  # Appendix B's outer guard is one second; "well inside" leaves room for host jitter.
  HOOK_BUDGET_SECONDS = 0.9

  def hook(event_name, timeout: 5.0, socket_path: nil)
    payload = {
      "hook_event_name" => event_name,
      "session_id" => "session-abc",
      "cwd" => Dir.pwd,
      "prompt" => "what did we decide about the spool?"
    }
    env = socket_path ? { "KIOKU_SOCKET_PATH" => socket_path } : {}
    Kioku::TestSupport::HostCommand.run("contextctl", "hook", env: env,
                                                              stdin_data: JSON.generate(payload), timeout: timeout)
  end

  def test_should_exit_cleanly_when_no_agent_socket_is_present
    result = hook("UserPromptSubmit")

    assert result.exited?, "the hook never exited with no agent socket present"
    assert_equal 0, result.exit_code, "stderr was: #{result.stderr[0, 300]}"
  end

  def test_should_complete_well_inside_the_one_second_hook_timeout_when_no_agent_socket_is_present
    result = hook("UserPromptSubmit")

    assert_operator result.elapsed, :<, HOOK_BUDGET_SECONDS,
                    "the hook took #{result.elapsed.round(3)}s with no agent to talk to"
  end

  # "Optional hooks return without enhancement" [plan §9].
  def test_should_return_without_added_context_when_no_agent_socket_is_present
    output = hook("UserPromptSubmit").stdout.strip
    parsed = output.empty? ? {} : JSON.parse(output)

    assert_nil parsed.dig("hookSpecificOutput", "additionalContext"),
               "the hook injected context it could not have retrieved"
  end

  # Q3. This used to run against a hook with NO agent socket, whose stdout is empty
  # by construction — so both refute_match calls matched against "" and passed for
  # every conceivable implementation, including one that rendered "saved": true.
  #
  # "never a false durable acknowledgment" [plan §9]; "queued means durable host
  # enqueue" [plan invariant 2]. The scenario the invariant is about is an agent
  # that ANSWERED: it reported a durable enqueue, and the hook must not promote
  # that into a save. The stub answers a real queued frame, and the requests
  # assertion means a hook that never made contact cannot pass by staying silent.
  def test_should_not_promote_a_queued_agent_answer_into_a_save
    reply = {
      "schema_version" => "kioku.tool.v1", "status" => "queued",
      "error" => { "code" => "kioku.queued", "message" => "durably enqueued, not committed" },
      "data" => { "saved" => false, "spool" => { "spool_entry_id" => "spool-1-1-stub" } }
    }

    result = Kioku::TestSupport::StubAgentSocket.serving(reply) do |stub|
      answer = hook("UserPromptSubmit", socket_path: stub.path)
      refute_empty stub.requests, "the hook never contacted the agent, so this proves nothing"
      answer
    end

    refute_match(/"saved"\s*:\s*true/, result.stdout,
                 "the hook reported a save from an answer that said queued")
    refute_match(/"(capture_status|status)"\s*:\s*"saved"/, result.stdout,
                 "the hook labelled a durable enqueue as a canonical commit")
  end

  # The absent-agent companion, stated as what it actually checks: the hook exits
  # without enhancement rather than inventing one. It makes no durability claim
  # because it makes no claim at all.
  def test_should_return_no_enhancement_when_no_agent_socket_is_present
    output = hook("UserPromptSubmit").stdout.strip

    assert_empty output, "the hook emitted output it could not have obtained"
  end

  def test_should_exit_cleanly_for_every_supported_event_when_no_agent_socket_is_present
    SUPPORTED_EVENTS.each do |event|
      result = hook(event)

      assert result.exited?, "#{event} never exited"
      assert_equal 0, result.exit_code, "#{event} exited #{result.exit_code}: #{result.stderr[0, 200]}"
    end
  end

end
