# frozen_string_literal: true

require "test_helper"
require_relative "../contracts/contract_fixtures"

# Response-envelope conformance, core side.
#
# Each case in conformance/envelope_response_cases.json is a golden wire object.
# Here the core must PRODUCE it; in the host suite the same object must be
# ACCEPTED. That is what makes D1 one decision rather than two: a core that starts
# rendering status "invalid" while the host knows only nine values would have its
# own output refused, and the pair of suites says so.
#
# The status is NOT taken from the case and handed to the serializer. It is derived
# from the error the core is reporting — which is what the boundary does
# (`status: error.wire_status`) — and the case's declared status is the assertion.
# Passing the answer in would measure nothing.
class ResponseConformanceTest < ActiveSupport::TestCase
  include Kioku::Test::ContractAssertions

  Fixtures = Kioku::Test::ContractFixtures

  test "should produce the golden wire object for every shared response case" do
    each_case(Fixtures.response_cases.fetch("cases"), side: "core") do |kase|
      wire = Fixtures.response_wire_for(kase)

      assert_equal wire, render(kase, wire), kase.fetch("id")
    end
  end

  # D1, at its sharpest. `response_fields.status` is required:true and status is
  # "the single discriminator"; a code that resolves to nothing makes the core omit
  # the key, and a caller then has to branch on `status || error.code`. That is
  # exactly how a core 500 came to be reported to a model as kioku.invalid_request.
  test "should render a status for every error the core is able to report" do
    statusless = reportable_codes.reject { |code| rendered_for(code).key?("status") }

    assert_empty statusless, "these errors render a response with no status discriminator"
  end

  test "should render the status the shared registry binds to every reportable error" do
    expected = reportable_codes.index_with { |code| Fixtures.errors.fetch(code).fetch("status") }
    actual = reportable_codes.index_with { |code| rendered_for(code)["status"] }

    assert_equal expected, actual
  end

  # The companion. "Render some status always" would satisfy the case above; the
  # registry binds each code to exactly one value, and a caller branching on the
  # discriminator has to get the right one.
  test "should render a null error and a success status when nothing failed" do
    payload = Context::Serialization::Response.call(**base_arguments.merge(status: :success))

    assert_equal "success", payload["status"]
    assert_nil payload["error"]
  end

  # D5. The contract's kioku.queued entry says replay after reconnect returns the
  # same idempotency receipt, so re-issuing with the same key and digest is the
  # mechanism by which a caller learns the commit outcome. Rendering retryable
  # false tells a caller to give up on a write that is waiting for it.
  test "should render the retryability the shared registry binds to every reportable error" do
    expected = reportable_codes.index_with { |code| Fixtures.errors.fetch(code).fetch("retryable") }
    actual = reportable_codes.index_with { |code| rendered_for(code).dig("error", "retryable") }

    assert_equal expected, actual
  end

  # The raised text stays on the server log. A response that echoes it hands the
  # model whatever the exception carried, which here is an idempotency key.
  test "should redact the raised message when an internal error reaches the wire" do
    raised = "PG::UniqueViolation on idempotency_key=customer-secret-42"
    error = Context::Errors::InternalError.new(raised)

    payload = Context::Serialization::Response.call(**base_arguments.merge(status: error.wire_status,
                                                                          error: error.to_wire))

    refute_includes payload.dig("error", "message").to_s, "customer-secret-42"
    assert_equal "an unexpected internal failure occurred", payload.dig("error", "message")
  end

  private

  # Every code the core can raise, which excludes the "ok" sentinel: it carries no
  # error body and is reported as status success with a null error.
  def reportable_codes
    Fixtures.errors.reject { |_, entry| entry.fetch("error_body") == false }.keys
  end

  def rendered_for(code)
    error = Context::Errors.fetch(code).new("operator facing message")

    Context::Serialization::Response.call(
      **base_arguments.merge(status: error.wire_status, error: error.to_wire)
    )
  end

  def render(kase, wire)
    spec = kase.fetch("render")
    error = error_for(spec, wire)

    Context::Serialization::Response.call(
      **base_arguments(wire).merge(
        status: error ? error.wire_status : spec["status"],
        error: error&.to_wire,
        data: spec["data"],
        coverage: spec["coverage"] || wire.fetch("coverage"),
        generation_vector: spec.key?("generation_vector") ? spec["generation_vector"] : wire["generation_vector"]
      )
    )
  end

  def error_for(spec, wire)
    code = spec["error_code"]
    return nil if code.nil?

    Context::Errors.fetch(code).new(spec["raised_message"] || wire.dig("error", "message"),
                                    details: wire.dig("error", "details") || {})
  end

  def base_arguments(wire = Fixtures.response_cases.fetch("wire_base"))
    {
      request_id: wire.fetch("request_id"),
      generation_vector: wire.fetch("generation_vector"),
      coverage: wire.fetch("coverage"),
      limits: wire.fetch("limits"),
      warnings: wire.fetch("warnings"),
      server_time: wire.fetch("server_time")
    }
  end
end
