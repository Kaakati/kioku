# frozen_string_literal: true

require_relative "../test_helper"
require "kioku/errors"

# The frozen error vocabulary. Every name and every status below is copied from the
# Phase 0 contract [contracts: errors[], envelope.response_fields.status].
class KiokuErrorsTest < Minitest::Test
  FROZEN_WIRE_NAMES = %w[
    ok
    kioku.partial_result
    kioku.queued
    kioku.revision_conflict
    kioku.scope_denied
    kioku.source_unavailable
    kioku.evidence_unavailable
    kioku.quota_exhausted
    kioku.deadline_exceeded
    kioku.invalid_request
    kioku.idempotency_conflict
    kioku.handle_unresolved
    kioku.project_binding_unresolved
    kioku.authority_violation
    kioku.evidence_required
    kioku.continuation_expired
    kioku.precondition_failed
    kioku.unsupported_operation
    kioku.unsupported_schema_version
    kioku.internal_error
  ].freeze

  FROZEN_STATUSES = %w[
    success partial queued conflict unauthorized_scope
    unavailable_source evidence_unavailable quota_exhausted deadline_expired
  ].freeze

  def test_should_register_exactly_the_frozen_wire_names_when_the_registry_is_listed
    assert_equal FROZEN_WIRE_NAMES.sort, Kioku::Errors.wire_names.sort
  end

  def test_should_round_trip_each_wire_name_when_a_descriptor_is_fetched_by_name
    FROZEN_WIRE_NAMES.each do |name|
      assert_equal name, Kioku::Errors.fetch(name).wire_name, "#{name} did not round-trip"
    end
  end

  def test_should_raise_when_an_unregistered_wire_name_is_fetched
    assert_raises(KeyError) { Kioku::Errors.fetch("kioku.made_up_condition") }
  end

  def test_should_expose_exactly_the_nine_response_statuses_when_statuses_are_listed
    assert_equal FROZEN_STATUSES.sort, Kioku::Errors.statuses.sort
  end

  def test_should_map_every_registered_code_to_a_frozen_status_or_to_none
    Kioku::Errors.wire_names.each do |name|
      status = Kioku::Errors.fetch(name).status
      next if status.nil?

      assert_includes FROZEN_STATUSES, status, "#{name} maps to an unfrozen status #{status.inspect}"
    end
  end

  # "queued means durable host enqueue only" [contracts: errors kioku.queued; plan invariant 2].
  def test_should_map_queued_to_the_queued_status_when_the_code_is_resolved
    assert_equal "queued", Kioku::Errors.fetch("kioku.queued").status
  end

  # "status=unauthorized_scope, data absent" [contracts: errors kioku.scope_denied].
  def test_should_map_scope_denied_to_unauthorized_scope_when_the_code_is_resolved
    assert_equal "unauthorized_scope", Kioku::Errors.fetch("kioku.scope_denied").status
  end

  # "status=unauthorized_scope with details.setup_required=true" [contracts: errors].
  def test_should_map_project_binding_unresolved_to_unauthorized_scope_when_the_code_is_resolved
    assert_equal "unauthorized_scope", Kioku::Errors.fetch("kioku.project_binding_unresolved").status
  end

  # "status=deadline_expired ... never reported as a save" [contracts: errors].
  def test_should_map_deadline_exceeded_to_deadline_expired_when_the_code_is_resolved
    assert_equal "deadline_expired", Kioku::Errors.fetch("kioku.deadline_exceeded").status
  end

  # "for v1 this returns HTTP/MCP-level error with code kioku.invalid_request and no
  # status field" [contracts: errors kioku.invalid_request; open_decisions "tenth status"].
  def test_should_carry_no_response_status_for_invalid_request_because_v1_has_no_invalid_status
    assert_nil Kioku::Errors.fetch("kioku.invalid_request").status
  end

  def test_should_map_every_conflict_family_code_to_the_conflict_status
    %w[
      kioku.revision_conflict kioku.idempotency_conflict kioku.authority_violation
      kioku.evidence_required kioku.continuation_expired kioku.precondition_failed
    ].each do |name|
      assert_equal "conflict", Kioku::Errors.fetch(name).status, "#{name} is not a conflict"
    end
  end

  # Embeddings, vector and hybrid search are out of scope, not deferred: "No field, enum
  # value, error code or capability in this contract refers to them" [contracts:
  # retrieval_modes_after_embedding_removal.explicitly_out_of_scope].
  def test_should_register_no_embedding_or_vector_code_when_the_registry_is_listed
    offending = Kioku::Errors.wire_names.grep(/embed|vector|semantic|hybrid|ann_|rerank/i)
    assert_empty offending, "out-of-scope retrieval codes are registered: #{offending.inspect}"
  end

  # An error carries operator-facing, content-redacted detail [contracts:
  # response_fields.error].
  def test_should_build_an_error_carrying_its_code_status_and_details_when_raised
    error = assert_raises(Kioku::Error) do
      raise Kioku::Error.new("kioku.quota_exhausted",
                             message: "spool full",
                             details: { "quota_kind" => "spool_disk", "limit" => 10, "observed" => 11 })
    end

    assert_equal "kioku.quota_exhausted", error.code
    assert_equal "quota_exhausted", error.status
    assert_equal "spool_disk", error.details["quota_kind"]
  end

  def test_should_refuse_to_build_an_error_when_the_code_is_not_a_frozen_wire_name
    assert_raises(KeyError) { Kioku::Error.new("kioku.not_a_real_code") }
  end
end
