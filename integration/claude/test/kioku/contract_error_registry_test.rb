# frozen_string_literal: true

require_relative "../test_helper"
require_relative "contract_fixtures"
require "kioku/errors"

# Error-registry parity, host side.
#
# `contracts/v1/errors.json` is the single table of wire names, and the status and
# retryability each one resolves to. Before it existed the host kept its own
# transcription and the core kept another, and nothing could diff them: the host
# marked kioku.queued retryable and the core did not (D5), and both left five codes
# with no status at all so a core 500 and a malformed request were indistinguishable
# on the discriminator (D1).
#
# This case reads the artifact and compares. It is not a restatement of the table:
# adding a code to errors.json, or changing one code's status, changes what these
# assertions demand without either file being edited.
class ContractErrorRegistryTest < Minitest::Test
  Fixtures = Kioku::TestSupport::ContractFixtures

  # D1. Today Kioku::Errors gives kioku.invalid_request, kioku.handle_unresolved,
  # kioku.unsupported_operation, kioku.unsupported_schema_version and
  # kioku.internal_error a nil status.
  def test_should_bind_every_wire_name_to_the_status_the_shared_registry_declares
    expected = Fixtures.errors.transform_values { |entry| entry.fetch("status") }
    actual = Kioku::Errors.wire_names.to_h { |name| [name, Kioku::Errors.fetch(name).status] }

    assert_equal expected, actual,
                 "the host error table disagrees with contracts/v1/errors.json"
  end

  # D5. The host is already correct here; the assertion exists so that "make both
  # sides agree" cannot be satisfied by changing the correct side.
  def test_should_bind_every_wire_name_to_the_retryability_the_shared_registry_declares
    expected = Fixtures.errors.transform_values { |entry| entry.fetch("retryable") }
    actual = Kioku::Errors.wire_names.to_h { |name| [name, Kioku::Errors.fetch(name).retryable] }

    assert_equal expected, actual,
                 "the host retry table disagrees with contracts/v1/errors.json"
  end

  # D1. The enum grew from the nine of plan 6.1 to eleven: `invalid` for a caller
  # fault and `internal_error` for a core fault.
  def test_should_publish_exactly_the_response_status_values_the_shared_contract_declares
    assert_equal Fixtures.response_statuses, Kioku::Errors.statuses
  end

  # The status enum is written twice in the artifact for readability
  # (common.schema.json for machines, contract.json for humans). If those two ever
  # disagree, every other assertion in this file is measuring against a coin flip.
  def test_should_read_one_status_enum_because_the_artifact_declares_it_in_one_shape
    assert_equal Fixtures.response_statuses, Fixtures.contract.dig("response_status", "values")
  end

  # A response may not carry a status the registry never binds to any code, and a
  # registry entry may not name a status the response envelope will not accept.
  def test_should_bind_every_declared_error_status_to_a_value_the_response_envelope_accepts
    unbound = Fixtures.errors.reject { |_, entry| Fixtures.response_statuses.include?(entry["status"]) }

    assert_empty unbound.keys, "errors.json binds these codes to a status outside the enum"
  end

  # A wire name the host cannot fetch is a condition the core can report and the
  # host will mistranslate; a name the host knows and the artifact does not is an
  # invented condition.
  def test_should_know_exactly_the_wire_names_the_shared_registry_declares
    assert_equal Fixtures.errors.keys.sort, Kioku::Errors.wire_names.sort
  end
end
