# frozen_string_literal: true

require "test_helper"
require_relative "contract_fixtures"

# Error-registry parity, core side.
#
# `contracts/v1/errors.json` is the one table of wire names, the response status
# each resolves to, whether a caller may retry, and the HTTP status the Rails
# surface answers with. Before it existed, Context::Errors and Kioku::Errors were
# two hand transcriptions that nothing could diff: they disagreed on
# kioku.queued.retryable (D5) and both left five codes with no status at all, so a
# core 500 and a malformed request were indistinguishable on the single
# discriminator (D1).
#
# These cases read the artifact and compare. Adding a code, or changing one code's
# status, changes what they demand without this file being edited.
class ErrorRegistryParityTest < ActiveSupport::TestCase
  Fixtures = Kioku::Test::ContractFixtures

  # D1. Today Context::Errors gives kioku.invalid_request, kioku.handle_unresolved,
  # kioku.unsupported_operation, kioku.unsupported_schema_version and
  # kioku.internal_error no `status:` at all, and Response omits the key for them.
  test "should bind every wire name to the response status the shared registry declares" do
    expected = registered_errors.transform_values { |entry| entry.fetch("status") }

    actual = expected.keys.index_with { |code| Context::Errors.fetch(code).wire_status&.to_s }

    assert_equal expected, actual, "the core error table disagrees with the shared errors.json"
  end

  # D5. The contract's own kioku.queued entry says "Replay after reconnect returns
  # the same idempotency receipt", so re-issuing is the mechanism by which a caller
  # learns the commit outcome — which is what retryable means. The core says false
  # and the host says true, which is a caller either giving up on a write that is
  # waiting for it, or not.
  test "should bind every wire name to the retryability the shared registry declares" do
    expected = registered_errors.transform_values { |entry| entry.fetch("retryable") }

    actual = expected.keys.index_with { |code| Context::Errors.fetch(code).retryable? }

    assert_equal expected, actual, "the core retry table disagrees with the shared errors.json"
  end

  # The HTTP mapping binds the Rails surface only; the host branches on code and
  # status and ignores it. It is still recorded in the artifact so a change to it
  # is a change to one file rather than to a table nobody can diff.
  test "should answer the http status the shared registry declares for every wire name" do
    expected = registered_errors.transform_values { |entry| entry.fetch("http_status") }

    actual = expected.keys.index_with { |code| http_code_for(Context::Errors.fetch(code)) }

    assert_equal expected, actual, "the core HTTP mapping disagrees with the shared errors.json"
  end

  test "should register exactly the wire names the shared registry declares" do
    assert_equal registered_errors.keys.sort, Context::Errors::REGISTRY.keys.sort
  end

  # A status the response envelope will not accept cannot be reported, so a code
  # bound to one is a condition the core can reach and cannot describe.
  test "should resolve every wire name to a value inside the declared response status enum" do
    declared = Fixtures.response_statuses
    outside = registered_errors.keys.reject do |code|
      declared.include?(Context::Errors.fetch(code).wire_status.to_s)
    end

    assert_empty outside, "these codes resolve to a status outside the declared enum"
  end

  private

  # "ok" is the success sentinel rather than a raisable condition: it carries no
  # error body and the core reports it by rendering status success with a null
  # error, so it has no Context::Errors class.
  def registered_errors
    Fixtures.errors.reject { |_, entry| entry.fetch("error_body") == false }
  end

  def http_code_for(klass)
    Rack::Utils::SYMBOL_TO_STATUS_CODE.fetch(klass.http_status, klass.http_status)
  end
end
