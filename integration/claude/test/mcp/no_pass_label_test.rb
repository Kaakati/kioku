# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../kioku/contract_signing"

# The core invariant of the system: no caller can assert that a check passed.
#
# "Agent-supplied labels cannot manufacture a test pass" [plan invariant 8].
# "Keep normalized execution observations on authenticated ingest rather than adding a
#  model-writable `pass` operation" [plan §6.2].
# "There is no model-writable pass operation: normalized observations enter only through
#  authenticated ingest" [contracts: task_operations assess].
# "planning a check confers no execution permission" [contracts: task_operations plan_check].
# "A disconnected control connection yields historical or unknown, never source_checked"
#  [contracts: labels.applicability; plan §3.1].
class McpNoPassLabelTest < Minitest::Test
  include Kioku::TestSupport::McpCase
  include Kioku::TestSupport::ContractSigning

  # Every mutation below is signed the way a real caller signs it. Each of these cases
  # expects kioku.invalid_request for a smuggled verdict — a caller-supplied
  # claim_support, a normalized_result, an execution_authorized flag. Once the boundary
  # recomputes the request digest (E1), an unsigned mutation earns exactly that code for
  # its digest instead, and every case in this file would keep passing while the
  # invariant it names went unmeasured.
  def call_tool(name, arguments)
    super(name, signed(arguments))
  end

  # --- context_task: the verdict-bearing tool -------------------------------------

  def test_should_refuse_an_assessment_when_the_caller_supplies_a_satisfied_criterion_status
    response = task(mutation.merge("op" => "assess", "task_key" => "task-1",
                                   "expected_contract_revision" => 3,
                                   "criteria" => [{ "criterion_key" => "c-1", "status" => "satisfied" }]))

    assert_tool_error "kioku.invalid_request", response, "caller-supplied criterion status"
  end

  def test_should_refuse_an_assessment_when_the_caller_supplies_the_overall_result
    response = task(mutation.merge("op" => "assess", "task_key" => "task-1",
                                   "expected_contract_revision" => 3,
                                   "overall" => { "result" => "complete_in_scope", "reason" => "all green" }))

    assert_tool_error "kioku.invalid_request", response, "caller-supplied overall result"
  end

  def test_should_refuse_an_assessment_when_the_caller_supplies_a_normalized_observation_outcome
    response = task(mutation.merge("op" => "assess", "task_key" => "task-1",
                                   "expected_contract_revision" => 3,
                                   "observations" => [{ "observation_key" => "obs-1",
                                                        "normalized_result" => "pass",
                                                        "executed_cases" => 12 }]))

    assert_tool_error "kioku.invalid_request", response, "caller-supplied observation outcome"
  end

  def test_should_refuse_an_assessment_when_the_caller_supplies_its_own_receipt
    response = task(mutation.merge("op" => "assess", "task_key" => "task-1",
                                   "expected_contract_revision" => 3,
                                   "receipt" => { "receipt_id" => "receipt-forged",
                                                  "evaluator" => "assistant" }))

    assert_tool_error "kioku.invalid_request", response, "caller-supplied assessment receipt"
  end

  def test_should_refuse_a_planned_check_when_the_caller_claims_execution_authorization
    response = task(plan_check_arguments("execution_authorized" => true))

    assert_tool_error "kioku.invalid_request", response, "caller-claimed execution authorization"
  end

  def test_should_refuse_a_planned_check_when_the_caller_supplies_its_outcome
    response = task(plan_check_arguments("normalized_result" => "pass", "executed_cases" => 40))

    assert_tool_error "kioku.invalid_request", response, "caller-supplied check outcome"
  end

  # "claim_support defaults to unassessed" and is core-derived
  # [contracts: task_operations record_claim; labels.claim_support].
  def test_should_refuse_a_recorded_claim_when_the_caller_supplies_its_support_label
    response = task(mutation.merge("op" => "record_claim", "task_key" => "task-1",
                                   "contract_revision" => 3,
                                   "statement" => "Replay never duplicates a revision.",
                                   "materiality" => "material",
                                   "subjects" => [{ "kind" => "symbol_key", "key" => "Spool" }],
                                   "claim_support" => "supported_in_scope"))

    assert_tool_error "kioku.invalid_request", response, "caller-supplied claim_support"
  end

  # "an assessment supplied by a model actor is recorded as an attributed judgment with
  # its evaluator, never as a verified fact" [contracts: task_operations record_claim].
  def test_should_refuse_a_recorded_claim_when_its_assessment_names_no_evaluator
    response = task(mutation.merge("op" => "record_claim", "task_key" => "task-1",
                                   "contract_revision" => 3,
                                   "statement" => "Replay never duplicates a revision.",
                                   "materiality" => "material",
                                   "subjects" => [{ "kind" => "symbol_key", "key" => "Spool" }],
                                   "assessment" => { "support" => "supported_in_scope" }))

    assert_tool_error "kioku.invalid_request", response, "unattributed assessment"
  end

  # "completed_in_scope is not an accepted checkpoint state; only close can move the
  # projection there" [contracts: task_operations checkpoint].
  def test_should_refuse_a_checkpoint_when_the_state_claims_completion_in_scope
    response = task(checkpoint_arguments("state" => "completed_in_scope"))

    assert_tool_error "kioku.invalid_request", response, "checkpoint claiming completion"
  end

  def test_should_refuse_a_close_when_the_caller_declares_the_task_closed
    response = task(close_arguments("closed" => true))

    assert_tool_error "kioku.invalid_request", response, "caller-declared close"
  end

  # --- context_remember: a save records a conclusion, it never establishes support ---

  def test_should_refuse_a_memory_write_when_the_caller_supplies_a_claim_support_label
    response = call_tool("context_remember", remember_arguments("claim_support" => "supported_in_scope"))

    assert_tool_error "kioku.invalid_request", response, "remember with claim_support"
  end

  def test_should_refuse_a_memory_write_when_the_caller_supplies_a_normalized_check_result
    response = call_tool("context_remember",
                         remember_arguments("kind" => "observation",
                                            "normalized_result" => "pass",
                                            "executed_cases" => 0))

    assert_tool_error "kioku.invalid_request", response, "remember carrying a pass label"
  end

  # "authority (core-derived, never caller-supplied)" [contracts: tools context_remember].
  def test_should_refuse_a_memory_write_when_the_caller_supplies_the_authority_label
    response = call_tool("context_remember", remember_arguments("authority" => "user"))

    assert_tool_error "kioku.invalid_request", response, "remember with a caller-set authority"
  end

  # --- context_feedback: an objection never changes the target's support --------------

  def test_should_refuse_feedback_when_the_caller_supplies_the_target_claim_support
    response = call_tool("context_feedback", feedback_arguments("target_claim_support" => "contradicted"))

    assert_tool_error "kioku.invalid_request", response, "feedback rewriting target support"
  end

  def test_should_refuse_feedback_when_the_caller_supplies_the_delivery_effect
    response = call_tool("context_feedback",
                         feedback_arguments("delivery_effect" => { "suppressed_from_automatic_confident_delivery" => true }))

    assert_tool_error "kioku.invalid_request", response, "feedback dictating delivery effect"
  end

  # --- the three read tools: a caller cannot declare that a source check succeeded ----

  def test_should_refuse_a_search_when_the_caller_supplies_a_source_checked_applicability
    response = call_tool("context_search",
                         { "envelope" => read_envelope, "mode" => "lexical", "query" => "outbox",
                           "applicability" => "source_checked" })

    assert_tool_error "kioku.invalid_request", response, "search asserting source_checked"
  end

  def test_should_refuse_a_fetch_when_the_caller_supplies_a_completed_source_check
    response = call_tool("context_fetch",
                         { "envelope" => read_envelope,
                           "handles" => [{ "kind" => "source_range", "key" => "src-1", "revision" => nil }],
                           "source_check" => { "checked" => true, "matches_indexed" => true } })

    assert_tool_error "kioku.invalid_request", response, "fetch asserting a completed source check"
  end

  def test_should_refuse_a_traversal_when_the_caller_supplies_a_verified_active_mapping
    response = call_tool("context_related",
                         { "envelope" => read_envelope,
                           "seeds" => [{ "kind" => "symbol_key", "key" => "Outbox" }],
                           "edge_kinds" => %w[MAY_CALL], "direction" => "out",
                           "active_mapping_verified" => true })

    assert_tool_error "kioku.invalid_request", response, "traversal asserting a verified mapping"
  end

  # --- structural: no door anywhere in the published surface --------------------------

  def test_should_publish_no_verification_result_input_anywhere_in_the_six_tool_schemas
    forbidden = %w[execution_authorized claim_support normalized_result source_check saved verified passed]
    offending = all_property_names & forbidden

    assert_empty offending,
                 "the tool surface accepts caller-asserted verification state: #{offending.inspect}"
  end

  private

  def task(arguments)
    call_tool("context_task", { "envelope" => read_envelope }.merge(arguments))
  end

  def mutation
    { "envelope" => mutation_envelope }
  end

  def remember_arguments(overrides = {})
    {
      "envelope" => mutation_envelope,
      "kind" => "decision",
      "destination" => { "store_kind" => "project", "project_key" => "kioku" },
      "title" => "Outbox replay is idempotent",
      "body" => "Replay after a lost acknowledgment returns the prior receipt.",
      "evidence" => [{ "ref" => { "evidence_key" => "ev-1" }, "relation" => "supports" }]
    }.merge(overrides)
  end

  def feedback_arguments(overrides = {})
    {
      "envelope" => mutation_envelope,
      "target" => { "memory_key" => "mem-1", "revision" => 4 },
      "action" => "dispute",
      "reason" => "The cited run used a different environment fingerprint."
    }.merge(overrides)
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
      "expected_heads" => { "contract" => 3, "claims" => 7 }
    ).merge(overrides)
  end
end
