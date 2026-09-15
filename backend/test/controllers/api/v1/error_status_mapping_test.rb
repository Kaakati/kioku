# frozen_string_literal: true

require "test_helper"

# Plan 4.1: "Use explicit conflict/validation errors mapped at the HTTP/MCP
# boundary." Plan 6.1 names the nine response discriminations; the frozen
# contract names the wire codes. The HTTP status each code maps to is not stated
# in either document, so the table below is the interpretation this suite pins
# down (recorded in the report):
#
#   400 invalid_request, unsupported_schema_version, unsupported_operation
#   401 (authentication, covered in ApiActorIdentityTest)
#   403 scope_denied, project_binding_unresolved
#   404 handle_unresolved            410 evidence_unavailable
#   409 revision_conflict, idempotency_conflict, authority_violation,
#       evidence_required, continuation_expired
#   412 precondition_failed          429 quota_exhausted
#   500 internal_error               503 source_unavailable
#   504 deadline_exceeded
#   200 partial_result (not a failure)    202 queued (not a save)
class ApiErrorStatusMappingTest < ActionDispatch::IntegrationTest
  include Kioku::Test::ProbeRoutes

  test "should answer 409 for every frozen conflict code" do
    %w[kioku.revision_conflict kioku.idempotency_conflict kioku.authority_violation
       kioku.evidence_required kioku.continuation_expired].each do |code|
      payload = probe_raising(code)

      assert_equal 409, response.status, "#{code} did not map to 409"
      assert_equal code, payload.dig("error", "code")
      assert_equal "conflict", payload["status"]
    end
  end

  test "should answer 403 for every frozen unauthorized scope code" do
    %w[kioku.scope_denied kioku.project_binding_unresolved].each do |code|
      payload = probe_raising(code)

      assert_equal 403, response.status, "#{code} did not map to 403"
      assert_equal code, payload.dig("error", "code")
      assert_nil payload["data"], "#{code} must not carry data"
    end
  end

  test "should answer 400 for every frozen request validation code" do
    %w[kioku.invalid_request kioku.unsupported_schema_version kioku.unsupported_operation].each do |code|
      payload = probe_raising(code)

      assert_equal 400, response.status, "#{code} did not map to 400"
      assert_equal code, payload.dig("error", "code")
    end
  end

  test "should answer 404 for an unresolved handle and 410 for unavailable evidence" do
    probe_raising("kioku.handle_unresolved")
    assert_equal 404, response.status

    payload = probe_raising("kioku.evidence_unavailable")
    assert_equal 410, response.status
    assert_equal "evidence_unavailable", payload["status"]
  end

  test "should answer 503 for an unavailable source and 504 for an expired deadline" do
    payload = probe_raising("kioku.source_unavailable")
    assert_equal 503, response.status
    assert_equal "unavailable_source", payload["status"]

    payload = probe_raising("kioku.deadline_exceeded")
    assert_equal 504, response.status
    assert_equal "deadline_expired", payload["status"]
  end

  test "should answer 429 and mark the error retryable when a quota is exhausted" do
    payload = probe_raising("kioku.quota_exhausted")

    assert_equal 429, response.status
    assert_equal "quota_exhausted", payload["status"]
    assert_equal true, payload.dig("error", "retryable")
  end

  test "should answer 412 when a close precondition failed" do
    payload = probe_raising("kioku.precondition_failed")

    assert_equal 412, response.status
    assert_equal "kioku.precondition_failed", payload.dig("error", "code")
  end

  test "should answer 200 and status partial when a bounded answer was still produced" do
    payload = probe_raising("kioku.partial_result")

    assert_equal 200, response.status
    assert_equal "partial", payload["status"]
    assert_equal "kioku.partial_result", payload.dig("error", "code")
  end

  test "should answer 202 and never render a durable enqueue as saved" do
    payload = probe_raising("kioku.queued")

    assert_equal 202, response.status
    assert_equal "queued", payload["status"]
    refute payload.dig("data", "saved"), "a queued write was rendered as saved"
  end

  test "should answer 500 with a redacted message when an unexpected failure escapes" do
    secret = "s3cr3t-bridge-credential"
    payload = probe_raising("kioku.internal_error",
                            message: "connect failed for postgres://kioku:#{secret}@db/kioku")

    assert_equal 500, response.status
    assert_equal "kioku.internal_error", payload.dig("error", "code")
    refute_includes response.body, secret
  end
end
