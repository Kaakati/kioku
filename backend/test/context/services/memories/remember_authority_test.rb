# frozen_string_literal: true

require "test_helper"

# Plan 1.3 ("Publishing a global lesson never upgrades assistant inference into
# direct user policy"; "A user can label a global rule mandatory"), invariant 12,
# and the frozen contract: `authority` is core-derived and never caller-supplied,
# `mandatory` is user authority only and an assistant actor setting it returns
# kioku.authority_violation. Invariant 11: a missing project binding is never
# read as permission to write globally.
class RememberAuthorityTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport

  GLOBAL_DESTINATION = { store_kind: :global, category: :engineering_decision }.freeze
  GLOBAL_APPLICABILITY = {
    languages: ["ruby"], frameworks: ["rails"], version_constraints: [], platforms: ["linux"],
    conditions: "Applies where concurrent writers can race a uniqueness check."
  }.freeze

  setup do
    arrange_project_with_durable_evidence
  end

  test "should refuse the write and persist nothing when an assistant actor marks a global rule mandatory" do
    result = remember_service.call(
      **remember_arguments(actor: bridge_actor(origin_role: :assistant),
                           destination: GLOBAL_DESTINATION,
                           applicability: GLOBAL_APPLICABILITY,
                           mandatory: true)
    )

    assert_equal :conflict, result.status
    assert_equal "kioku.authority_violation", result.error_code
    assert_equal 0, memory_revision_count
    assert_equal 0, receipt_count("idem-1")
  end

  test "should record assistant authority when an assistant actor writes a global record" do
    result = remember_service.call(
      **remember_arguments(actor: bridge_actor(origin_role: :assistant),
                           destination: GLOBAL_DESTINATION,
                           applicability: GLOBAL_APPLICABILITY)
    )

    assert_equal "assistant", revisions_for(result.memory_key).last.authority
  end

  test "should default an assistant authored global record to proposed rather than active" do
    result = remember_service.call(
      **remember_arguments(actor: bridge_actor(origin_role: :assistant),
                           destination: GLOBAL_DESTINATION,
                           applicability: GLOBAL_APPLICABILITY)
    )

    assert_equal "proposed", revisions_for(result.memory_key).last.lifecycle
  end

  test "should record user authority when a user actor writes the identical global record" do
    result = remember_service.call(
      **remember_arguments(actor: bridge_actor(origin_role: :user),
                           destination: GLOBAL_DESTINATION,
                           applicability: GLOBAL_APPLICABILITY)
    )

    revision = revisions_for(result.memory_key).last
    assert_equal "user", revision.authority
    assert_equal "active", revision.lifecycle
  end

  test "should refuse a global record that declares no applicability conditions" do
    result = remember_service.call(
      **remember_arguments(destination: GLOBAL_DESTINATION, applicability: nil)
    )

    assert_equal "kioku.invalid_request", result.error_code
    assert_equal 0, memory_revision_count
  end

  test "should refuse to write globally and persist nothing when a project destination names no project" do
    result = remember_service.call(
      **remember_arguments(destination: { store_kind: :project, project_key: nil })
    )

    assert_equal "kioku.project_binding_unresolved", result.error_code
    assert_equal 0, memory_count(store_kind: "global")
    assert_equal 0, memory_revision_count
  end
end
