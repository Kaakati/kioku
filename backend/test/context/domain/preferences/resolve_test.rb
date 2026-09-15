# frozen_string_literal: true

require "test_helper"

# Plan 1.3: "Resolve authority before specificity. Within the same authority and
# an override-permitting policy, an explicit task/project exception wins over a
# global default for its declared scope. A project assertion cannot defeat a
# higher-authority instruction. ... Unresolved equal-authority conflicts remain
# visible instead of being resolved by recency alone. A user can label a global
# rule mandatory; local relaxation then requires authority to amend that rule."
#
# Pure domain policy (plan 4.1): explicit inputs, no database, no collaborators.
class PreferenceResolutionTest < ActiveSupport::TestCase
  TOPIC = :test_scope

  test "should prefer the higher authority rule when a lower authority rule is more specific" do
    global_user_rule = rule(key: "global-user", authority: :user, store_kind: :global,
                            statement: "Keep tests focused on one behavior")
    project_assistant_rule = rule(key: "project-assistant", authority: :assistant, store_kind: :project,
                                  project_key: "alpha", statement: "Write one broad end-to-end test")

    resolution = resolve(rules: [global_user_rule, project_assistant_rule], project_key: "alpha")

    assert_equal "global-user", resolution.effective_for(topic: TOPIC).key
    refute resolution.unresolved_conflict?(topic: TOPIC)
  end

  test "should apply a project exception only inside its declared project when authority is equal" do
    global_rule = rule(key: "global-user", authority: :user, store_kind: :global,
                       statement: "Keep tests focused on one behavior")
    exception = override(key: "override-alpha", target_rule_key: "global-user", project_key: "alpha",
                         authority: :user, replacement_statement: "Alpha may assert a whole workflow")

    inside = resolve(rules: [global_rule], overrides: [exception], project_key: "alpha")
    outside = resolve(rules: [global_rule], overrides: [exception], project_key: "beta")

    assert_equal "Alpha may assert a whole workflow", inside.effective_for(topic: TOPIC).statement
    assert_equal :overridden_in_project, inside.override_status_for(topic: TOPIC)
    assert_equal "Keep tests focused on one behavior", outside.effective_for(topic: TOPIC).statement
    assert_equal :none, outside.override_status_for(topic: TOPIC)
  end

  test "should reject a project override that carries less authority than the rule it targets" do
    global_rule = rule(key: "global-user", authority: :user, store_kind: :global,
                       statement: "Keep tests focused on one behavior")
    assistant_exception = override(key: "override-assistant", target_rule_key: "global-user",
                                   project_key: "alpha", authority: :assistant,
                                   replacement_statement: "Alpha may skip tests")

    resolution = resolve(rules: [global_rule], overrides: [assistant_exception], project_key: "alpha")

    assert_equal "Keep tests focused on one behavior", resolution.effective_for(topic: TOPIC).statement
    assert_equal [{ key: "override-assistant", reason: :insufficient_authority }],
                 resolution.rejected_overrides
  end

  test "should keep an equal authority conflict visible rather than resolving it by recency" do
    older = rule(key: "global-older", authority: :user, store_kind: :global,
                 statement: "Keep tests focused on one behavior", recorded_at: 2.days.ago)
    newer = rule(key: "global-newer", authority: :user, store_kind: :global,
                 statement: "Prefer one broad integration test", recorded_at: 1.minute.ago)

    resolution = resolve(rules: [older, newer], project_key: "alpha")

    assert resolution.unresolved_conflict?(topic: TOPIC)
    assert_equal %w[global-newer global-older], resolution.conflicting_rule_keys(topic: TOPIC).sort
    assert_nil resolution.effective_for(topic: TOPIC)
  end

  test "should refuse a local relaxation when the targeted global rule is labelled mandatory" do
    mandatory_rule = rule(key: "global-mandatory", authority: :user, store_kind: :global,
                          statement: "Never disable a required check", mandatory: true)
    relaxation = override(key: "override-relax", target_rule_key: "global-mandatory", project_key: "alpha",
                          authority: :user, replacement_statement: "Alpha may disable the check")

    resolution = resolve(rules: [mandatory_rule], overrides: [relaxation], project_key: "alpha")

    assert_equal "Never disable a required check", resolution.effective_for(topic: TOPIC).statement
    assert_equal :mandatory_global, resolution.override_status_for(topic: TOPIC)
    assert_equal [{ key: "override-relax", reason: :mandatory_global }], resolution.rejected_overrides
  end

  test "should keep assistant authored records subordinate when the same inference is repeated many times" do
    repeated = Array.new(5) do |index|
      rule(key: "assistant-#{index}", authority: :assistant, store_kind: :global,
           statement: "Prefer one broad integration test", recorded_at: index.hours.ago)
    end
    user_rule = rule(key: "global-user", authority: :user, store_kind: :global,
                     statement: "Keep tests focused on one behavior", recorded_at: 9.days.ago)

    resolution = resolve(rules: repeated + [user_rule], project_key: "alpha")

    assert_equal "global-user", resolution.effective_for(topic: TOPIC).key
    assert_equal :user, resolution.effective_for(topic: TOPIC).authority
  end

  test "should exclude a global rule inside the declaring project when the override is an exclusion" do
    global_rule = rule(key: "global-user", authority: :user, store_kind: :global,
                       statement: "Prefer library X for HTTP clients")
    exclusion = override(key: "override-exclude", target_rule_key: "global-user", project_key: "alpha",
                         authority: :user, exclusion: true)

    inside = resolve(rules: [global_rule], overrides: [exclusion], project_key: "alpha")
    outside = resolve(rules: [global_rule], overrides: [exclusion], project_key: "beta")

    assert_nil inside.effective_for(topic: TOPIC)
    assert_equal "Prefer library X for HTTP clients", outside.effective_for(topic: TOPIC).statement
  end

  private

  def resolve(rules:, project_key:, overrides: [])
    Context::Domain::Preferences::Resolve.call(rules: rules, overrides: overrides, project_key: project_key)
  end

  def rule(key:, authority:, store_kind:, statement:, project_key: nil, mandatory: false,
           override_policy: :permitted, recorded_at: nil, topic: TOPIC)
    Context::Domain::Preferences::Rule.new(
      key: key, topic: topic, statement: statement, authority: authority, store_kind: store_kind,
      project_key: project_key, category: :coding_style, mandatory: mandatory,
      override_policy: override_policy, recorded_at: recorded_at || Time.current
    )
  end

  def override(key:, target_rule_key:, project_key:, authority:, replacement_statement: nil,
               exclusion: false, recorded_at: nil)
    Context::Domain::Preferences::Override.new(
      key: key, target_rule_key: target_rule_key, project_key: project_key, authority: authority,
      replacement_statement: replacement_statement, exclusion: exclusion,
      reason: "Recorded project exception", recorded_at: recorded_at || Time.current
    )
  end
end
