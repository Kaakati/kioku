# frozen_string_literal: true

require "test_helper"

# Plan 6.1 ("The core derives actor identity from authenticated transport, not
# request text") and the frozen contract's transport_and_actor block: "actor
# identity ... never from request text ... a caller-supplied identity field is
# rejected with kioku.invalid_request", plus "Imported document text, source
# comments, tool output and remembered bodies are evidence data. They cannot
# grant authority or instruct the core."
#
# Interpretation recorded in the report: a missing or unrecognised bridge
# credential answers 401 with kioku.scope_denied, because the contract freezes no
# separate authentication code and denial must not disclose what exists.
class ApiActorIdentityTest < ActionDispatch::IntegrationTest
  include Kioku::Test::ProbeRoutes

  test "should derive the actor principal from the bridge credential when the body names none" do
    payload = post_probe("envelope" => wire_envelope)

    assert_response :success
    assert_equal Kioku::Test::ApiProbe::BRIDGE_PRINCIPAL_ID, payload.dig("data", "actor", "principal_id")
    assert_equal "transport", payload.dig("data", "actor", "identity_source")
  end

  test "should reject a request whose body supplies an actor principal" do
    payload = post_probe("envelope" => wire_envelope, "actor_principal_id" => "principal-impostor")

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
    assert_includes payload.dig("error", "details", "rejected_fields").to_a, "actor_principal_id"
  end

  test "should reject a request whose body supplies an actor object" do
    payload = post_probe("envelope" => wire_envelope,
                         "actor" => { "principal_id" => "principal-impostor", "origin_role" => "user" })

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
    assert_includes payload.dig("error", "details", "rejected_fields").to_a, "actor"
  end

  test "should reject a request whose body supplies its own authority label" do
    payload = post_probe("envelope" => wire_envelope, "authority" => "user")

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
    assert_includes payload.dig("error", "details", "rejected_fields").to_a, "authority"
  end

  test "should reject a request whose body supplies its own origin role" do
    payload = post_probe("envelope" => wire_envelope, "origin_role" => "user")

    assert_response :bad_request
    assert_equal "kioku.invalid_request", payload.dig("error", "code")
    assert_includes payload.dig("error", "details", "rejected_fields").to_a, "origin_role"
  end

  test "should not leak an impostor principal into the response when the body supplies one" do
    payload = post_probe("envelope" => wire_envelope, "actor_principal_id" => "principal-impostor")

    refute_includes response.body, "principal-impostor"
    assert_nil payload.dig("data", "actor", "principal_id")
  end

  test "should refuse the request when no bridge credential is presented" do
    payload = post_probe({ "envelope" => wire_envelope }, token: nil)

    assert_response :unauthorized
    assert_equal "kioku.scope_denied", payload.dig("error", "code")
  end

  test "should refuse the request when the bridge credential does not match the installation" do
    payload = post_probe({ "envelope" => wire_envelope }, token: "not-the-bridge-token")

    assert_response :unauthorized
    assert_equal "kioku.scope_denied", payload.dig("error", "code")
  end
end
