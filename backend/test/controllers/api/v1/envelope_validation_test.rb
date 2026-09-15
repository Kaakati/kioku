# frozen_string_literal: true

require "test_helper"

# Plan 6.1 common envelope and the frozen contract's request_fields: every
# request carries schema_version, request_id, a bounded relative deadline and a
# requested scope; mutations additionally carry an actor-scoped idempotency key,
# a request digest and an expected revision where applicable.
#
# Interpretation recorded in the report: every tool arrives as a POST, so the
# controller declares whether it is a read or a mutation with `kioku_operation`;
# the mutation envelope fields are required only for the latter.
class ApiEnvelopeValidationTest < ActionDispatch::IntegrationTest
  include Kioku::Test::ProbeRoutes

  test "should reject a request whose schema_version major is not supported" do
    payload = post_probe("envelope" => wire_envelope("schema_version" => "kioku.tool.v2"))

    assert_response :bad_request
    assert_equal "kioku.unsupported_schema_version", payload.dig("error", "code")
  end

  test "should reject a request that carries no schema_version" do
    payload = post_probe("envelope" => wire_envelope.except("schema_version"))

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
  end

  test "should reject a request that carries no request_id" do
    payload = post_probe("envelope" => wire_envelope.except("request_id"))

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
  end

  test "should reject a deadline outside the bounded one to thirty thousand millisecond range" do
    payload = post_probe("envelope" => wire_envelope("deadline_ms" => 45_000))

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
    assert_includes payload.dig("error", "details", "fields").to_a, "deadline_ms"
  end

  test "should reject a project scoped request that names no project_key" do
    payload = post_probe("envelope" => wire_envelope("scope" => { "store" => "project" }))

    assert_response :forbidden
    assert_equal "kioku.project_binding_unresolved", payload.dig("error", "code")
    assert_equal true, payload.dig("error", "details", "setup_required")
  end

  test "should reject a mutation that supplies no idempotency key" do
    payload = post_probe("envelope" => wire_envelope.except("idempotency_key"))

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
    assert_includes payload.dig("error", "details", "fields").to_a, "idempotency_key"
  end

  test "should reject a mutation whose request_digest is not a sha256 hex digest" do
    payload = post_probe("envelope" => wire_envelope("request_digest" => "sha1:deadbeef"))

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
    assert_includes payload.dig("error", "details", "fields").to_a, "request_digest"
  end

  test "should reject a mutation whose expected_revision is below one" do
    payload = post_probe("envelope" => wire_envelope("expected_revision" => 0))

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
    assert_includes payload.dig("error", "details", "fields").to_a, "expected_revision"
  end

  test "should accept a read request that carries no idempotency fields" do
    envelope = wire_read_envelope
    payload = post_read_probe("envelope" => envelope)

    assert_response :success
    assert_equal envelope["request_id"], payload["request_id"]
  end

  test "should echo the request_id and the contract version on an accepted request" do
    envelope = wire_envelope
    payload = post_probe("envelope" => envelope)

    assert_response :success
    assert_equal envelope["request_id"], payload["request_id"]
    assert_equal "kioku.tool.v1", payload["schema_version"]
  end

  test "should convert the relative deadline into an absolute deadline_at on an accepted request" do
    payload = post_probe("envelope" => wire_envelope("deadline_ms" => 5000))

    assert_response :success
    deadline_at = Time.iso8601(payload.dig("limits", "deadline_at"))
    assert_operator deadline_at, :>, Time.now.utc
    assert_operator deadline_at, :<=, Time.now.utc + 6
  end

  test "should always render the generation vector coverage and server time on an accepted request" do
    payload = post_probe("envelope" => wire_envelope)

    assert_response :success
    refute_nil payload["generation_vector"]
    refute_nil payload["coverage"]
    refute_nil payload["server_time"]
  end
end
