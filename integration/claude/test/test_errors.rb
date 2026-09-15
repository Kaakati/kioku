# frozen_string_literal: true

require_relative "test_helper"

class TestErrors < Minitest::Test
  EXPECTED_WIRE_NAMES = %w[
    ok kioku.partial_result kioku.queued kioku.revision_conflict kioku.scope_denied
    kioku.source_unavailable kioku.evidence_unavailable kioku.quota_exhausted
    kioku.deadline_exceeded kioku.invalid_request kioku.idempotency_conflict
    kioku.handle_unresolved kioku.project_binding_unresolved kioku.authority_violation
    kioku.evidence_required kioku.continuation_expired kioku.precondition_failed
    kioku.unsupported_operation kioku.unsupported_schema_version kioku.internal_error
  ].freeze

  def test_all_twenty_frozen_wire_names_exist
    assert_equal 20, Kioku::WIRE_CODES.length
    assert_equal EXPECTED_WIRE_NAMES.sort, Kioku::WIRE_CODES.sort
  end

  def test_nine_response_statuses
    assert_equal 9, Kioku::STATUSES.length
    assert_includes Kioku::STATUSES, "deadline_expired"
  end

  def test_partial_and_queued_are_not_failures
    refute_includes Kioku::FAILED_STATUSES, "partial"
    refute_includes Kioku::FAILED_STATUSES, "queued"
    refute_includes Kioku::FAILED_STATUSES, "success"
    assert_equal 6, Kioku::FAILED_STATUSES.length
  end

  def test_code_to_status_mapping_matches_contract
    assert_equal "conflict", Kioku::Error.new("kioku.revision_conflict", "x").status
    assert_equal "unauthorized_scope", Kioku::Error.new("kioku.scope_denied", "x").status
    assert_equal "unauthorized_scope", Kioku::Error.new("kioku.project_binding_unresolved", "x").status
    assert_equal "unavailable_source", Kioku::Error.new("kioku.source_unavailable", "x").status
    assert_equal "deadline_expired", Kioku::Error.new("kioku.deadline_exceeded", "x").status
    assert_equal "queued", Kioku::Error.new("kioku.queued", "x").status
  end

  # The frozen contract says validation failure has no status field in v1.
  def test_transport_level_codes_carry_no_status
    assert_nil Kioku::Error.new("kioku.invalid_request", "x").status
    assert_nil Kioku::Error.new("kioku.unsupported_schema_version", "x").status
    assert_nil Kioku::Error.new("kioku.handle_unresolved", "x").status
    assert_nil Kioku::Error.new("kioku.unsupported_operation", "x").status
  end

  def test_unknown_wire_name_is_rejected
    assert_raises(ArgumentError) { Kioku::Error.new("kioku.made_up", "x") }
  end

  def test_error_object_shape
    error = Kioku::Error.new("kioku.quota_exhausted", "full", details: { "limit" => 1 }, retry_after_ms: 50)
    object = error.to_error_object
    assert_equal %w[code message retryable retry_after_ms details].sort, object.keys.sort
    assert_equal true, object["retryable"]
    assert_equal 50, object["retry_after_ms"]
  end

  def test_transport_unavailable_is_an_internal_error_with_a_component
    error = Kioku::TransportUnavailable.new("context-agent", "Errno::ENOENT")
    assert_equal "kioku.internal_error", error.code
    assert_equal "context-agent", error.component
    assert_equal "transport_unavailable", error.details["reason"]
    assert error.retryable?
  end
end
