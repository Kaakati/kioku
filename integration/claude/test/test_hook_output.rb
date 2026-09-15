# frozen_string_literal: true

require_relative "test_helper"

# The hook events do not share an output contract. Only the two with a
# documented additional-context contract may write to stdout; everything else
# writes nothing, because a wrong guess corrupts the hook protocol.
class TestHookOutput < Minitest::Test
  def capsule(text)
    { "status" => "success", "data" => { "additional_context" => text } }
  end

  def test_only_session_start_and_user_prompt_submit_emit_output
    %w[SessionStart UserPromptSubmit].each do |event|
      refute_nil Kioku::Hooks::Output.render(event, capsule("two open checks"))
    end

    %w[PreToolUse PostToolUse PostToolUseFailure SubagentStart SubagentStop
       PreCompact PostCompact Stop SessionEnd].each do |event|
      assert_nil Kioku::Hooks::Output.render(event, capsule("two open checks"))
    end
  end

  def test_rendered_output_matches_the_hook_specific_shape
    line = Kioku::Hooks::Output.render("UserPromptSubmit", capsule("one constraint applies"))
    parsed = JSON.parse(line)
    assert_equal "UserPromptSubmit", parsed.dig("hookSpecificOutput", "hookEventName")
    assert_equal "one constraint applies", parsed.dig("hookSpecificOutput", "additionalContext")
    refute parsed.key?("permissionDecision")
    refute parsed.key?("decision")
  end

  # No addition is a valid result.
  def test_no_capsule_means_no_output
    assert_nil Kioku::Hooks::Output.render("SessionStart", nil)
    assert_nil Kioku::Hooks::Output.render("SessionStart", capsule(nil))
    assert_nil Kioku::Hooks::Output.render("SessionStart", capsule("   "))
    assert_nil Kioku::Hooks::Output.render("SessionStart", { "status" => "success", "data" => {} })
  end

  def test_a_failed_capsule_adds_nothing
    failed = { "status" => "unauthorized_scope", "data" => { "additional_context" => "leaked" } }
    assert_nil Kioku::Hooks::Output.render("SessionStart", failed)
  end

  def test_additional_context_is_bounded
    line = Kioku::Hooks::Output.render("SessionStart", capsule("x" * 20_000))
    text = JSON.parse(line).dig("hookSpecificOutput", "additionalContext")
    assert_equal Kioku::Hooks::Output::CONTEXT_LIMIT, text.bytesize
  end

  def test_pre_tool_use_never_captures_and_never_decides
    behaviour = Kioku::Hooks::Dispatcher::EVENTS.fetch("PreToolUse")
    assert_equal false, behaviour[:capture]
    assert_equal false, behaviour[:enhance]
  end

  def test_every_registered_event_has_a_declared_behaviour
    assert_equal 11, Kioku::Hooks::Dispatcher::EVENTS.length
    Kioku::Hooks::Dispatcher::EVENTS.each_value do |behaviour|
      assert_equal %i[capture enhance].sort, behaviour.keys.sort
    end
  end
end
