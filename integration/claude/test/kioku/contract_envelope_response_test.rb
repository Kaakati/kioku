# frozen_string_literal: true

require_relative "../test_helper"
require_relative "contract_fixtures"
require_relative "contract_assertions"
require "kioku/envelope"

# Response-envelope conformance, host side.
#
# The same golden responses the core must PRODUCE are read here as payloads the
# host must ACCEPT or REFUSE. That is what makes D1 a single decision rather than
# two: if the core starts rendering `status: "invalid"` and the host still knows
# only nine status values, the host refuses the core's own output and these cases
# say so.
class ContractEnvelopeResponseTest < Minitest::Test
  include Kioku::TestSupport::ContractAssertions

  Fixtures = Kioku::TestSupport::ContractFixtures

  def test_should_reach_the_declared_outcome_and_wire_code_for_every_shared_response_case
    each_case(Fixtures.response_cases.fetch("cases"), side: "host") do |kase|
      expect = kase.fetch("host_expect")
      context = kase.fetch("id")

      parsed = assert_outcome(expect, context) { parse(kase) }
      assert_parsed_response(parsed, expect, context) if expect.fetch("outcome") == "accepted"
    end
  end

  # D1, stated behaviourally. The registry binds each code to exactly one status;
  # a core that paired them freely could report a denial as a conflict and a caller
  # would retry a scope it will never be granted. Five codes carry no status in the
  # host's own table today, so for those five the pairing is unpoliced and any
  # status at all is accepted.
  def test_should_refuse_a_response_pairing_a_registered_code_with_a_status_the_registry_denies_it
    accepted = error_bodied_codes.reject do |code, entry|
      refused?(response_wire(status: wrong_status_for(entry.fetch("status")), code: code))
    end

    assert_empty accepted.keys,
                 "these codes were accepted under a status the shared registry does not bind to them"
  end

  # The companion. Without it the case above is satisfied by refusing every
  # non-success response, and D1 could be "resolved" by making the host stricter
  # instead of making both sides agree.
  def test_should_accept_a_response_pairing_every_registered_code_with_the_status_the_registry_binds
    refused = error_bodied_codes.select do |code, entry|
      refused?(response_wire(status: entry.fetch("status"), code: code))
    end

    assert_empty refused.keys,
                 "these codes were refused under the very status the shared registry binds to them"
  end

  # The anti-regression guard for D1's other direction: making `status` optional
  # again to accommodate a core that omits it would silently restore the defect.
  def test_should_refuse_a_response_that_omits_the_status_discriminator_entirely
    wire = Fixtures.response_cases.fetch("wire_base").reject { |key, _| key == "status" }

    error = assert_raises(Kioku::Error) { Kioku::Envelope.parse_response(wire) }
    assert_equal "kioku.invalid_request", error.code
  end

  private

  def parse(kase)
    Kioku::Envelope.parse_response(Fixtures.response_wire_for(kase),
                                   expected_request_id: kase["expected_request_id"])
  end

  def assert_parsed_response(parsed, expect, context)
    assert_equal expect.fetch("status"), parsed.status, "#{context}: wrong status"
    if expect["code"]
      assert_equal expect["code"], parsed.error&.code, "#{context}: wrong error code"
    end
    return unless expect.key?("retryable")

    assert_equal expect.fetch("retryable"), parsed.error&.retryable, "#{context}: wrong retryability"
  end

  def error_bodied_codes
    Fixtures.errors.select { |_, entry| entry.fetch("error_body") }
  end

  # A status that is wrong for this code and is nonetheless one the host already
  # knows, so a refusal here is a refusal of the PAIRING and not of an unknown
  # enum value.
  def wrong_status_for(status)
    status == "conflict" ? "partial" : "conflict"
  end

  def response_wire(status:, code:)
    Fixtures.response_cases.fetch("wire_base").merge(
      "status" => status,
      "data" => nil,
      "error" => { "code" => code, "message" => "operator facing message",
                   "retryable" => false, "retry_after_ms" => nil, "details" => {} }
    )
  end

  def refused?(wire)
    Kioku::Envelope.parse_response(wire)
    false
  rescue Kioku::Error
    true
  end
end
