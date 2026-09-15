# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../kioku/contract_signing"
require_relative "../kioku/published_surface"

# "a discriminated eight-operation schema that is not an arbitrary command or SQL
# interface" [contracts: tools context_task.purpose; task_operations[]].
# Each operation declares its own required fields, so a payload that is valid for one
# operation is not valid for another and a free-form payload is not valid for any.
class McpTaskDiscriminationTest < Minitest::Test
  include Kioku::TestSupport::McpCase
  include Kioku::TestSupport::PublishedSurface
  include Kioku::TestSupport::ContractSigning

  EIGHT_OPS = %w[get set_contract record_claim propose plan_check assess checkpoint close].freeze

  # Every mutation below is signed the way a real caller signs it. Once the boundary
  # recomputes the request digest (E1), an unsigned mutation is refused for its digest
  # whatever else the case names, and each of these cases — all of which expect
  # kioku.invalid_request — would keep passing while measuring the digest instead of
  # the missing subject, the invented enum value or the blank summary it describes.
  def call_tool(name, arguments)
    super(name, signed(arguments))
  end

  # Read through the branches, so what is measured is the eight operations rather than
  # one schema's way of spelling them: the artifact discriminates context_task as a
  # oneOf whose branches each pin `op` with a const, and a case reading
  # `properties.op.enum` would compare nil to this list and fail while appearing to
  # count operations.
  def test_should_offer_exactly_the_eight_operations_when_the_task_schema_is_published
    assert_equal EIGHT_OPS.sort, values_offered_for("context_task", "op").sort
  end

  # "Covers unknown context_task op" [contracts: errors kioku.unsupported_operation].
  def test_should_refuse_the_call_when_the_operation_is_not_one_of_the_eight
    response = task("op" => "run_sql", "task_key" => "task-1")

    assert_tool_error "kioku.unsupported_operation", response, "unknown op"
  end

  def test_should_refuse_the_call_when_no_operation_is_supplied
    response = task("task_key" => "task-1")

    assert_tool_error "kioku.invalid_request", response, "missing op discriminator"
  end

  # A free-form payload is refused: the schema is a discriminated union, not an envelope
  # around arbitrary content.
  def test_should_refuse_the_call_when_the_payload_carries_an_unrecognized_free_form_field
    response = task("op" => "get", "task_key" => "task-1",
                    "payload" => { "statement" => "select * from memories" })

    assert_tool_error "kioku.invalid_request", response, "free-form payload field"
  end

  # Fields do not cross operations: a verifier digest belongs to plan_check alone.
  def test_should_refuse_the_call_when_a_field_from_another_operation_is_supplied
    response = task("op" => "get", "task_key" => "task-1", "verifier_digest" => "sha256:deadbeef")

    assert_tool_error "kioku.invalid_request", response, "plan_check field on op=get"
  end

  def test_should_refuse_a_get_when_no_task_key_is_supplied
    assert_tool_error "kioku.invalid_request", task("op" => "get"), "get without a task key"
  end

  # [contracts: task_operations set_contract.required_fields].
  def test_should_refuse_a_set_contract_when_the_objective_is_blank
    response = task(mutation.merge("op" => "set_contract", "objective" => "  ",
                                   "scope" => contract_scope, "criteria" => [],
                                   "origin_event_ref" => "event-1"))

    assert_tool_error "kioku.invalid_request", response, "set_contract with a blank objective"
  end

  def test_should_refuse_a_set_contract_when_no_origin_event_is_referenced
    response = task(mutation.merge("op" => "set_contract", "objective" => "Ship the host package",
                                   "scope" => contract_scope, "criteria" => []))

    assert_tool_error "kioku.invalid_request", response, "set_contract without an origin event"
  end

  # [contracts: task_operations record_claim.required_fields].
  def test_should_refuse_a_record_claim_when_the_materiality_is_not_declared
    response = task(mutation.merge("op" => "record_claim", "task_key" => "task-1",
                                   "contract_revision" => 3, "statement" => "The outbox is idempotent.",
                                   "subjects" => [{ "kind" => "symbol_key", "key" => "Outbox" }]))

    assert_tool_error "kioku.invalid_request", response, "record_claim without materiality"
  end

  def test_should_refuse_a_record_claim_when_the_materiality_is_outside_the_frozen_enum
    response = task(mutation.merge("op" => "record_claim", "task_key" => "task-1",
                                   "contract_revision" => 3, "statement" => "The outbox is idempotent.",
                                   "materiality" => "critical",
                                   "subjects" => [{ "kind" => "symbol_key", "key" => "Outbox" }]))

    assert_tool_error "kioku.invalid_request", response, "record_claim with an invented materiality"
  end

  def test_should_refuse_a_record_claim_when_it_names_no_subject
    response = task(mutation.merge("op" => "record_claim", "task_key" => "task-1",
                                   "contract_revision" => 3, "statement" => "The outbox is idempotent.",
                                   "materiality" => "material", "subjects" => []))

    assert_tool_error "kioku.invalid_request", response, "record_claim without subjects"
  end

  # "proposal: object {problem, mechanism, expected_effect, preconditions, change_scope,
  # discriminating_check}" [contracts: task_operations propose.required_fields].
  def test_should_refuse_a_propose_when_the_proposal_names_no_discriminating_check
    proposal = full_proposal
    proposal.delete("discriminating_check")
    response = task(mutation.merge("op" => "propose", "task_key" => "task-1",
                                   "contract_revision" => 3, "proposal" => proposal))

    assert_tool_error "kioku.invalid_request", response, "propose without a discriminating check"
  end

  def test_should_refuse_a_propose_when_the_proposal_is_supplied_as_free_text
    response = task(mutation.merge("op" => "propose", "task_key" => "task-1",
                                   "contract_revision" => 3, "proposal" => "just try turning it off and on"))

    assert_tool_error "kioku.invalid_request", response, "propose with a free-text proposal"
  end

  # [contracts: task_operations plan_check.required_fields].
  def test_should_refuse_a_plan_check_when_the_verifier_digest_is_absent
    arguments = plan_check_arguments
    arguments.delete("verifier_digest")

    assert_tool_error "kioku.invalid_request", task(arguments), "plan_check without a verifier digest"
  end

  def test_should_refuse_a_plan_check_when_the_input_assurance_level_is_invented
    response = task(plan_check_arguments("minimum_input_assurance" => "trust_me"))

    assert_tool_error "kioku.invalid_request", response, "plan_check with an invented assurance level"
  end

  def test_should_refuse_a_plan_check_when_the_check_kind_is_outside_the_frozen_enum
    response = task(plan_check_arguments("check_kind" => "vibes"))

    assert_tool_error "kioku.invalid_request", response, "plan_check with an invented check kind"
  end

  # "Appendix E requires task.revision == requested_revision" [contracts: task_operations assess].
  def test_should_refuse_an_assess_when_no_expected_contract_revision_is_supplied
    response = task(mutation.merge("op" => "assess", "task_key" => "task-1"))

    assert_tool_error "kioku.invalid_request", response, "assess without an expected contract revision"
  end

  # [contracts: task_operations checkpoint.required_fields].
  def test_should_refuse_a_checkpoint_when_the_summary_is_blank
    response = task(checkpoint_arguments("summary" => ""))

    assert_tool_error "kioku.invalid_request", response, "checkpoint with a blank summary"
  end

  # "close moves the task projection to completed_in_scope only against a still-applicable
  # receipt" [contracts: task_operations close.notes].
  def test_should_refuse_a_close_when_no_assessment_receipt_is_named
    arguments = close_arguments
    arguments.delete("receipt_id")

    assert_tool_error "kioku.invalid_request", task(arguments), "close without a receipt"
  end

  def test_should_refuse_a_close_when_the_caller_observed_no_heads
    arguments = close_arguments
    arguments.delete("expected_heads")

    assert_tool_error "kioku.invalid_request", task(arguments), "close without observed heads"
  end

  # Negative control: op=get is a read, so the read envelope must not be refused for
  # missing mutation fields [contracts: tools context_task.required_inputs].
  def test_should_not_refuse_a_get_as_invalid_when_it_uses_the_read_envelope
    response = task("op" => "get", "task_key" => "task-1")

    refute_tool_error "kioku.invalid_request", response, "op=get with a read envelope"
  end

  # The seven mutating operations carry the mutation envelope.
  def test_should_refuse_a_checkpoint_when_the_envelope_carries_no_idempotency_key
    arguments = checkpoint_arguments
    arguments["envelope"] = read_envelope

    assert_tool_error "kioku.invalid_request", task(arguments), "checkpoint with a read envelope"
  end

  private

  def task(arguments)
    call_tool("context_task", { "envelope" => read_envelope }.merge(arguments))
  end

  def mutation
    { "envelope" => mutation_envelope }
  end

  def contract_scope
    { "project_key" => "kioku", "repository_keys" => ["kioku"], "worktree_keys" => ["main"] }
  end

  def full_proposal
    {
      "problem" => "Duplicate revisions under concurrent writers",
      "mechanism" => "Optimistic expected-revision check on the head row",
      "expected_effect" => "The stale writer fails and nothing is written",
      "preconditions" => [{ "kind" => "schema", "detail" => "head table carries a revision column" }],
      "change_scope" => [{ "kind" => "symbol_key", "key" => "Context::Storage::MemoryWriter" }],
      "discriminating_check" => "Two concurrent writers at the same expected revision"
    }
  end

  def plan_check_arguments(overrides = {})
    mutation.merge(
      "op" => "plan_check",
      "task_key" => "task-1",
      "contract_revision" => 3,
      "criterion_key" => "criterion-1",
      "check_kind" => "test",
      "expected_snapshot_ref" => "manifest-1",
      "expected_environment_fingerprint" => "env-1",
      "verifier_digest" => "sha256:#{'b' * 64}",
      "minimum_input_assurance" => "immutable_snapshot",
      "definition" => { "version" => 1, "runner" => "minitest" }
    ).merge(overrides)
  end

  def checkpoint_arguments(overrides = {})
    mutation.merge(
      "op" => "checkpoint",
      "task_key" => "task-1",
      "contract_revision" => 3,
      "state" => "implementing",
      "summary" => "Spool replay covered; assessment gate outstanding."
    ).merge(overrides)
  end

  def close_arguments(overrides = {})
    mutation.merge(
      "op" => "close",
      "task_key" => "task-1",
      "expected_contract_revision" => 3,
      "receipt_id" => "receipt-1",
      "expected_heads" => { "contract" => 3, "claims" => 7, "source_epoch" => 12 }
    ).merge(overrides)
  end
end
