# frozen_string_literal: true

require_relative "../test_helper"
require "kioku/envelope"

# The host validates what the core returned before rendering it, so a malformed or
# dishonest response is never passed to Claude as an answer
# [contracts: envelope.response_fields; plan §6.1].
class KiokuResponseEnvelopeTest < Minitest::Test
  def parse(payload, **kwargs)
    Kioku::Envelope.parse_response(payload, **kwargs)
  end

  def refuse(payload, **kwargs)
    assert_raises(Kioku::Error) { parse(payload, **kwargs) }
  end

  def test_should_expose_the_status_when_a_complete_success_response_is_parsed
    assert_equal "success", parse(success_response).status
  end

  %w[generation_vector coverage limits warnings server_time status request_id schema_version].each do |field|
    define_method("test_should_reject_the_response_when_the_required_#{field}_field_is_absent") do
      payload = success_response
      payload.delete(field)

      assert_equal "kioku.invalid_request", refuse(payload).code
    end
  end

  # "The nine-way discrimination set of Plan §6.1. This is the single discriminator"
  # [contracts: response_fields.status]. There is no tenth status in v1
  # [contracts: open_decisions "the tenth transport-level status"].
  def test_should_reject_the_response_when_the_status_is_outside_the_nine_way_set
    assert_equal "kioku.invalid_request", refuse(success_response("status" => "invalid")).code
  end

  # "present for every status except success ... Present on partial and queued too, so a
  # caller can branch on one field" [contracts: response_fields.error].
  def test_should_reject_the_response_when_a_partial_status_carries_no_error_body
    payload = success_response("status" => "partial", "error" => nil)

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_reject_the_response_when_a_queued_status_carries_no_error_body
    payload = success_response("status" => "queued", "error" => nil, "data" => { "saved" => false })

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_reject_the_response_when_a_success_status_carries_an_error_body
    payload = success_response("error" => error_body("kioku.partial_result"))

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_reject_the_response_when_the_error_code_is_not_a_frozen_wire_name
    payload = success_response("status" => "partial", "error" => error_body("kioku.something_else"))

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_reject_the_response_when_the_error_code_contradicts_the_status
    payload = success_response("status" => "partial", "error" => error_body("kioku.scope_denied"))

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_accept_the_response_when_the_error_code_matches_its_frozen_status
    payload = success_response("status" => "partial",
                               "error" => error_body("kioku.partial_result"),
                               "data" => { "items" => [] },
                               "coverage" => { "state" => "partial" })

    assert_equal "kioku.partial_result", parse(payload).error.code
  end

  # "data ... Absent on unauthorized_scope and deadline_expired"
  # [contracts: response_fields.data].
  def test_should_reject_the_response_when_an_unauthorized_scope_status_carries_data
    payload = success_response("status" => "unauthorized_scope",
                               "error" => error_body("kioku.scope_denied"),
                               "data" => { "items" => [] })

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_reject_the_response_when_a_deadline_expired_status_carries_data
    payload = success_response("status" => "deadline_expired",
                               "error" => error_body("kioku.deadline_exceeded"),
                               "data" => { "items" => [] })

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  # "queued ... {spool_entry_id, producer_key, producer_epoch, producer_sequence,
  # saved:false}. This is the only honest answer when commit is unavailable; it must
  # never be rendered as saved" [contracts: errors kioku.queued; plan invariant 2].
  def test_should_reject_the_response_when_a_queued_status_reports_the_write_as_saved
    payload = queued_response("saved" => true)

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_reject_the_response_when_a_queued_status_omits_the_saved_discriminator
    payload = queued_response
    payload["data"].delete("saved")

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_reject_the_response_when_a_queued_status_omits_its_spool_entry_id
    payload = queued_response
    payload["data"]["spool"].delete("spool_entry_id")

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_accept_the_response_when_a_queued_status_reports_the_write_as_unsaved
    assert_equal false, parse(queued_response).data.fetch("saved")
  end

  # "A deadline expiry is never reported as a save" [contracts: errors kioku.deadline_exceeded].
  def test_should_reject_the_response_when_a_failed_status_reports_the_write_as_saved
    payload = success_response("status" => "unavailable_source",
                               "error" => error_body("kioku.source_unavailable"),
                               "data" => { "saved" => true })

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  # "Echoed on every response and on every receipt" [contracts: request_fields.request_id].
  def test_should_reject_the_response_when_the_echoed_request_id_does_not_match_the_request
    payload = success_response("request_id" => uuid_v7)

    assert_equal "kioku.invalid_request", refuse(payload, expected_request_id: uuid_v7).code
  end

  def test_should_accept_the_response_when_the_echoed_request_id_matches_the_request
    identifier = uuid_v7
    payload = success_response("request_id" => identifier)

    assert_equal identifier, parse(payload, expected_request_id: identifier).request_id
  end

  def test_should_reject_the_response_when_the_schema_version_major_is_unsupported
    payload = success_response("schema_version" => "kioku.tool.v2")

    assert_equal "kioku.unsupported_schema_version", refuse(payload).code
  end

  # "warnings ... required: true, default []" [contracts: response_fields.warnings].
  def test_should_reject_the_response_when_a_warning_entry_is_not_a_coded_record
    payload = success_response("warnings" => ["host_disconnected"])

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_expose_a_coded_warning_when_the_response_carries_a_non_fatal_condition
    payload = success_response(
      "warnings" => [{ "code" => "host_disconnected", "detail" => "control connection down", "count" => 1 }]
    )

    assert_equal "host_disconnected", parse(payload).warnings.first["code"]
  end

  private

  def queued_response(data_overrides = {})
    success_response(
      "status" => "queued",
      "error" => error_body("kioku.queued", "retryable" => true),
      "data" => {
        "saved" => false,
        "spool" => {
          "spool_entry_id" => "spool-0001",
          "producer_key" => "agent-a",
          "producer_epoch" => 3,
          "producer_sequence" => 17
        }
      }.merge(data_overrides)
    )
  end
end
