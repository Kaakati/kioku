# frozen_string_literal: true

require_relative "../test_helper"
require "kioku/envelope"

# The common request envelope [contracts: envelope.request_fields; plan §6.1].
class KiokuRequestEnvelopeTest < Minitest::Test
  def parse(payload, mutation: false)
    Kioku::Envelope.parse_request(payload, mutation: mutation)
  end

  def refuse(payload, mutation: false)
    error = assert_raises(Kioku::Error) { parse(payload, mutation: mutation) }
    error
  end

  def test_should_expose_the_declared_scope_when_a_well_formed_read_envelope_is_parsed
    request = parse(read_envelope)

    assert_equal "project", request.scope.store
    assert_equal "kioku", request.scope.project_key
    assert_equal 3_000, request.deadline_ms
  end

  def test_should_reject_the_request_when_request_id_is_absent
    payload = read_envelope
    payload.delete("request_id")

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  # "string (UUIDv7, 36 chars)" [contracts: request_fields.request_id].
  def test_should_reject_the_request_when_request_id_is_not_a_uuid_v7
    payload = read_envelope("request_id" => "3f2504e0-4f89-41d3-9a0c-0305e82c3301")

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_reject_the_request_when_request_id_is_not_thirty_six_characters
    payload = read_envelope("request_id" => "01930f4e0f8a7c219f3a0b3c9a7d21ab")

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  # "Rejected with kioku.unsupported_schema_version if the major does not match"
  # [contracts: request_fields.schema_version].
  def test_should_reject_the_request_when_the_schema_version_major_is_unsupported
    payload = read_envelope("schema_version" => "kioku.tool.v2")

    assert_equal "kioku.unsupported_schema_version", refuse(payload).code
  end

  def test_should_reject_the_request_when_the_schema_version_is_from_another_contract
    payload = read_envelope("schema_version" => "kioku.host.v1")

    assert_equal "kioku.unsupported_schema_version", refuse(payload).code
  end

  # "Minor additions are additive-only" [contracts: request_fields.schema_version].
  def test_should_accept_the_request_when_only_the_schema_version_minor_is_unknown
    request = parse(read_envelope("schema_version" => "kioku.tool.v1.7"))

    assert_equal 1, request.schema_major
  end

  # "integer (1..30000)" [contracts: request_fields.deadline_ms].
  def test_should_reject_the_request_when_deadline_ms_is_zero
    assert_equal "kioku.invalid_request", refuse(read_envelope("deadline_ms" => 0)).code
  end

  def test_should_reject_the_request_when_deadline_ms_exceeds_thirty_thousand
    assert_equal "kioku.invalid_request", refuse(read_envelope("deadline_ms" => 30_001)).code
  end

  def test_should_accept_the_request_when_deadline_ms_is_exactly_the_upper_bound
    assert_equal 30_000, parse(read_envelope("deadline_ms" => 30_000)).deadline_ms
  end

  # A relative budget, not a timestamp: a string is not a budget
  # [contracts: request_fields.deadline_ms "Relative budget, not an absolute timestamp"].
  def test_should_reject_the_request_when_deadline_ms_is_not_an_integer
    assert_equal "kioku.invalid_request", refuse(read_envelope("deadline_ms" => "3000")).code
  end

  def test_should_reject_the_request_when_the_scope_store_is_not_a_declared_value
    payload = read_envelope("scope" => { "store" => "everything", "project_key" => "kioku" })

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  # "A missing or ambiguous binding returns kioku.project_binding_unresolved and must
  # never fall back to global" [contracts: request_fields.scope.project_key; plan invariant 11].
  def test_should_reject_a_project_scoped_request_when_the_project_key_is_absent
    payload = read_envelope("scope" => { "store" => "project" })
    error = refuse(payload)

    assert_equal "kioku.project_binding_unresolved", error.code
    assert_equal true, error.details["setup_required"]
  end

  def test_should_reject_a_both_scoped_request_when_the_project_key_is_absent
    payload = read_envelope("scope" => { "store" => "both" })

    assert_equal "kioku.project_binding_unresolved", refuse(payload).code
  end

  # "A global operation must declare store=global explicitly; it is never reached by
  # omitting project_key" [contracts: request_fields.scope.store].
  def test_should_accept_a_global_request_only_when_the_store_is_declared_global
    request = parse(read_envelope("scope" => { "store" => "global" }))

    assert_equal "global", request.scope.store
    assert_nil request.scope.project_key
  end

  # "Absent this field, other projects' records ... are excluded"
  # [contracts: request_fields.scope.cross_project_keys].
  def test_should_default_cross_project_keys_to_empty_when_the_field_is_absent
    assert_equal [], parse(read_envelope).scope.cross_project_keys
  end

  # "a caller-supplied identity field is rejected with kioku.invalid_request"
  # [contracts: envelope.transport_and_actor.actor_identity].
  def test_should_reject_the_request_when_the_caller_supplies_an_actor_principal_id
    payload = read_envelope("actor_principal_id" => "principal-forged")

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  # "Derived by the core from origin_role and transport, never accepted from the caller"
  # [contracts: labels.authority].
  def test_should_reject_the_request_when_the_caller_supplies_an_authority_label
    payload = read_envelope("authority" => "user")

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  def test_should_reject_the_request_when_the_caller_supplies_an_origin_role
    payload = read_envelope("origin_role" => "user")

    assert_equal "kioku.invalid_request", refuse(payload).code
  end

  # Mutations additionally carry an actor-scoped idempotency key and request digest
  # [contracts: request_fields.idempotency_key / request_digest; plan §6.1].
  def test_should_reject_a_mutation_when_the_idempotency_key_is_absent
    payload = mutation_envelope
    payload.delete("idempotency_key")

    assert_equal "kioku.invalid_request", refuse(payload, mutation: true).code
  end

  def test_should_reject_a_mutation_when_the_request_digest_is_absent
    payload = mutation_envelope
    payload.delete("request_digest")

    assert_equal "kioku.invalid_request", refuse(payload, mutation: true).code
  end

  # '"sha256:" + 64 lowercase hex' [contracts: request_fields.request_digest].
  def test_should_reject_a_mutation_when_the_request_digest_uses_uppercase_hex
    payload = mutation_envelope("request_digest" => "sha256:#{'A' * 64}")

    assert_equal "kioku.invalid_request", refuse(payload, mutation: true).code
  end

  def test_should_reject_a_mutation_when_the_request_digest_has_no_algorithm_prefix
    payload = mutation_envelope("request_digest" => "f" * 64)

    assert_equal "kioku.invalid_request", refuse(payload, mutation: true).code
  end

  def test_should_reject_a_mutation_when_the_idempotency_key_exceeds_one_hundred_twenty_eight_characters
    payload = mutation_envelope("idempotency_key" => "k" * 129)

    assert_equal "kioku.invalid_request", refuse(payload, mutation: true).code
  end

  # "Null/absent means create" and revisions are bigint >= 1
  # [contracts: request_fields.expected_revision; plan invariant 4].
  def test_should_treat_an_absent_expected_revision_as_a_create_when_a_mutation_is_parsed
    assert_nil parse(mutation_envelope, mutation: true).expected_revision
  end

  def test_should_reject_a_mutation_when_the_expected_revision_is_below_one
    payload = mutation_envelope("expected_revision" => 0)

    assert_equal "kioku.invalid_request", refuse(payload, mutation: true).code
  end
end
