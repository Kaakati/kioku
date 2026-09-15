# frozen_string_literal: true

require "test_helper"

# Plan 6.3: "Validate loopback Host/Origin, mutation CSRF protections, payload
# size, root containment and symlink resolution." Plan 3/3.1: only api (7310)
# and ui (7311) publish host ports and only on 127.0.0.1, so a request that
# claims any other host or origin did not come from the trusted loopback bridge
# or the management UI.
#
# Interpretation recorded in the report: a non-loopback Host or Origin answers
# 403 with kioku.scope_denied, reusing a frozen code rather than inventing one.
class ApiLoopbackOriginTest < ActionDispatch::IntegrationTest
  include Kioku::Test::ProbeRoutes

  test "should refuse a request whose Host header is not loopback" do
    payload = post_probe({ "envelope" => wire_envelope }, host: "kioku.evil.example")

    assert_response :forbidden
    assert_equal "kioku.scope_denied", payload.dig("error", "code")
  end

  test "should refuse a request whose Origin header is not loopback" do
    payload = post_probe({ "envelope" => wire_envelope },
                         headers: { "HTTP_ORIGIN" => "https://kioku.evil.example" })

    assert_response :forbidden
    assert_equal "kioku.scope_denied", payload.dig("error", "code")
  end

  test "should refuse a request whose Host rebinds a loopback name onto a public suffix" do
    payload = post_probe({ "envelope" => wire_envelope }, host: "127.0.0.1.evil.example")

    assert_response :forbidden
    assert_equal "kioku.scope_denied", payload.dig("error", "code")
  end

  test "should accept a request from the published loopback api port" do
    post_probe({ "envelope" => wire_envelope }, host: "127.0.0.1:7310")

    assert_response :success
  end

  test "should accept a request whose Origin is the loopback management ui" do
    post_probe({ "envelope" => wire_envelope },
               headers: { "HTTP_ORIGIN" => "http://localhost:7311" })

    assert_response :success
  end

  test "should accept a request from the IPv6 loopback address" do
    post_probe({ "envelope" => wire_envelope }, host: "[::1]:7310")

    assert_response :success
  end
end
