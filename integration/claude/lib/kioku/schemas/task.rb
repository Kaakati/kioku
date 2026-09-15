# frozen_string_literal: true

module Kioku
  module Schemas
    # context_task: one discriminated eight-operation schema.
    #
    # The discrimination is real in two layers. The JSON Schema oneOf matches
    # exactly one branch on the op const, so each op's own required fields are
    # enforced and nothing else can satisfy it; the adapter then rejects fields
    # that belong to a different op (FIELDS_BY_OP). There is no free-form
    # payload, no command string and no pass operation: normalized observations
    # enter only through authenticated ingest.
    module Task
      OPS = %w[get set_contract record_claim propose plan_check assess checkpoint close].freeze
      TASK_STATES = %w[investigating implementing checking blocked completed_in_scope interrupted].freeze
      # completed_in_scope is not an accepted checkpoint state. Only close moves
      # the projection there, and only against a still-applicable receipt.
      CHECKPOINT_STATES = %w[investigating implementing checking blocked interrupted].freeze
      INCLUDES = %w[contract criteria claims candidates checks observations assessments checkpoints receipts].freeze
      HEAD_NAMES = %w[contract criteria claims candidates checks source_epoch policy_generation deletion_epoch].freeze

      REQUIRED_BY_OP = {
        "get" => %w[task_key],
        "set_contract" => %w[objective scope criteria origin_event_ref],
        "record_claim" => %w[task_key contract_revision statement materiality subjects],
        "propose" => %w[task_key contract_revision proposal],
        "plan_check" => %w[task_key contract_revision criterion_key check_kind expected_snapshot_ref
                           expected_environment_fingerprint verifier_digest minimum_input_assurance definition],
        "assess" => %w[task_key expected_contract_revision],
        "checkpoint" => %w[task_key contract_revision state summary],
        "close" => %w[task_key expected_contract_revision receipt_id expected_heads]
      }.freeze

      OPTIONAL_BY_OP = {
        "get" => %w[include at_contract_revision limit cursor],
        "set_contract" => %w[task_key constraints known_exclusions state],
        "record_claim" => %w[assumptions supporting_evidence conflicting_evidence alternative_explanations
                             contradiction_conditions assessment],
        "propose" => %w[supporting_evidence contrary_evidence risks verdict retry_conditions
                        supersedes_candidate_version_key origin],
        "plan_check" => %w[candidate_version_key expected_distinguishing_outcomes priority],
        "assess" => %w[criterion_keys snapshot_ref environment_fingerprint include_evidence],
        "checkpoint" => %w[open_questions next_check_ref evidence context_epoch persist_as_memory],
        "close" => %w[closing_note limitations_acknowledged]
      }.freeze

      FIELDS_BY_OP = OPS.to_h do |op|
        [op, (%w[envelope op token_budget] + REQUIRED_BY_OP.fetch(op) + OPTIONAL_BY_OP.fetch(op)).freeze]
      end.freeze

      module_function

      def schema
        {
          "type" => "object",
          "required" => %w[envelope op],
          "additionalProperties" => false,
          "properties" => properties,
          "oneOf" => OPS.map { |op| branch(op) }
        }
      end

      def branch(op)
        matcher = { "properties" => { "op" => { "const" => op } },
                    "required" => %w[envelope op] + REQUIRED_BY_OP.fetch(op) }
        return matcher unless op == "checkpoint"

        matcher["properties"]["state"] = { "enum" => CHECKPOINT_STATES }
        matcher
      end

      def properties
        common = Kioku::Schemas::Common
        {
          "envelope" => common.envelope(mutation: true),
          "op" => { "type" => "string", "enum" => OPS },
          "task_key" => { "type" => "string", "minLength" => 1 },
          "token_budget" => { "type" => "integer", "minimum" => 1 }
        }.merge(get_fields(common)).merge(contract_fields(common))
          .merge(claim_fields(common)).merge(check_fields(common)).merge(close_fields(common))
      end

      def get_fields(common)
        {
          "include" => { "type" => "array", "items" => { "type" => "string", "enum" => INCLUDES } },
          "at_contract_revision" => { "type" => "integer", "minimum" => 1,
                                      "description" => "Historical view; always labelled applicability=historical." },
          "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 200 },
          "cursor" => common.cursor
        }
      end

      def contract_fields(common)
        {
          "objective" => { "type" => "string", "minLength" => 1 },
          "scope" => contract_scope(common),
          "criteria" => criteria,
          "origin_event_ref" => { "type" => "string", "minLength" => 1,
                                  "description" => "The capture event this contract derives from." },
          "constraints" => common.string_array("References to governing memories."),
          "known_exclusions" => common.string_array("Explicitly excluded work."),
          "state" => { "type" => "string", "enum" => TASK_STATES }
        }
      end

      def contract_scope(common)
        { "type" => "object", "additionalProperties" => false, "required" => ["project_key"],
          "description" => "A task always resolves to exactly one project.",
          "properties" => {
            "project_key" => { "type" => "string", "minLength" => 1 },
            "repository_keys" => common.string_array("Repositories in scope."),
            "worktree_keys" => common.string_array("Worktrees in scope.") } }
      end

      def criteria
        { "type" => "array", "minItems" => 0,
          "description" => "An empty list is legal and leaves the task unassessable, never vacuously " \
                           "complete. Authority is recorded per requirement: an assistant cannot relax a " \
                           "user-authored required criterion, only propose the change.",
          "items" => { "type" => "object", "additionalProperties" => false,
                       "required" => %w[criterion_key description required authority],
                       "properties" => {
                         "criterion_key" => { "type" => "string", "minLength" => 1 },
                         "description" => { "type" => "string", "minLength" => 1 },
                         "required" => { "type" => "boolean" },
                         "authority" => { "type" => "string", "enum" => %w[user assistant system] },
                         "verification_policy" => { "type" => "object" } } } }
      end

      def claim_fields(common)
        {
          "contract_revision" => { "type" => "integer", "minimum" => 1,
                                   "description" => "Must equal the current contract revision." },
          "statement" => { "type" => "string", "minLength" => 1 },
          "materiality" => { "type" => "string", "enum" => %w[material informational] },
          "subjects" => { "type" => "array", "minItems" => 1,
                          "items" => common.typed_handle(common::SEED_KINDS, "What the claim is about.") },
          "assumptions" => common.string_array("Stated assumptions."),
          "supporting_evidence" => common.evidence_array("Evidence offered in support."),
          "conflicting_evidence" => common.evidence_array("Evidence that conflicts; never dropped to fit."),
          "alternative_explanations" => common.string_array("Other explanations considered."),
          "contradiction_conditions" => { "type" => "string", "description" => "What would refute this claim." },
          "assessment" => claim_assessment,
          "proposal" => proposal(common),
          "contrary_evidence" => common.evidence_array("Contrary evidence for a candidate."),
          "risks" => common.string_array("Known risks."),
          "verdict" => { "type" => "string", "enum" => %w[open selected rejected] },
          "retry_conditions" => { "type" => "string",
                                  "description" => "What must change to justify retrying a rejected candidate." },
          "supersedes_candidate_version_key" => { "type" => "string" },
          "origin" => { "type" => "string", "enum" => %w[local_case external_research model_synthesis] }
        }
      end

      def claim_assessment
        { "type" => "object", "additionalProperties" => false, "required" => %w[support evaluator],
          "description" => "An assessment supplied by a model actor is recorded as an attributed judgment " \
                           "with its evaluator, never as a verified fact.",
          "properties" => {
            "support" => { "type" => "string",
                           "enum" => %w[unassessed supported_in_scope contradicted inconclusive] },
            "evaluator" => { "type" => "string", "minLength" => 1 },
            "rationale" => { "type" => "string" } } }
      end

      def proposal(common)
        { "type" => "object", "additionalProperties" => false,
          "required" => %w[problem mechanism expected_effect preconditions change_scope discriminating_check],
          "description" => "Candidate versions are immutable: any content change mints a new " \
                           "candidate_version_key rather than editing one.",
          "properties" => {
            "problem" => { "type" => "string", "minLength" => 1 },
            "mechanism" => { "type" => "string", "minLength" => 1 },
            "expected_effect" => { "type" => "string", "minLength" => 1 },
            "preconditions" => preconditions,
            "change_scope" => { "type" => "array",
                                "items" => common.typed_handle(common::SEED_KINDS, "What the change touches.") },
            "discriminating_check" => { "type" => "string", "minLength" => 1 } } }
      end

      def preconditions
        kinds = %w[framework_version dependency schema state workload platform constraint]
        { "type" => "array",
          "items" => { "type" => "object", "additionalProperties" => false,
                       "required" => %w[kind detail],
                       "properties" => { "kind" => { "type" => "string", "enum" => kinds },
                                         "detail" => { "type" => "string" } } } }
      end

      def check_fields(common)
        {
          "criterion_key" => { "type" => "string", "minLength" => 1 },
          "check_kind" => { "type" => "string", "enum" => %w[test inspection analysis review] },
          "expected_snapshot_ref" => { "type" => "string", "minLength" => 1 },
          "expected_environment_fingerprint" => { "type" => "string", "minLength" => 1 },
          "verifier_digest" => { "type" => "string", "minLength" => 1 },
          "minimum_input_assurance" => { "type" => "string", "enum" => %w[immutable_snapshot observed_bookends] },
          "definition" => { "type" => "object",
                            "description" => "Versioned verifier/input definition. Planning a check confers " \
                                             "no execution permission: the response always carries " \
                                             "execution_authorized=false." },
          "candidate_version_key" => { "type" => "string" },
          "expected_distinguishing_outcomes" => common.string_array("Outcomes that would distinguish."),
          "priority" => priority,
          "expected_contract_revision" => { "type" => "integer", "minimum" => 1 },
          "criterion_keys" => common.string_array("Subset of criteria to assess."),
          "snapshot_ref" => { "type" => "string" },
          "environment_fingerprint" => { "type" => "string" },
          "include_evidence" => { "type" => "boolean" }
        }
      end

      def priority
        { "type" => "object", "additionalProperties" => false,
          "description" => "Explicit ordinal factors. No numeric information-gain score is presented " \
                           "as calibrated.",
          "properties" => {
            "decisiveness" => { "type" => "string", "enum" => %w[low medium high] },
            "affected_requirement" => { "type" => "string" },
            "feasibility" => { "type" => "string", "enum" => %w[low medium high] },
            "expected_latency_ms" => { "type" => "integer", "minimum" => 0 },
            "expected_token_cost" => { "type" => "integer", "minimum" => 0 },
            "execution_scope" => { "type" => "string" } } }
      end

      def close_fields(common)
        {
          "summary" => { "type" => "string", "minLength" => 1 },
          "open_questions" => common.string_array("Questions still open at this checkpoint."),
          "next_check_ref" => { "type" => "string" },
          "evidence" => common.evidence_array("Evidence attached to this checkpoint."),
          "context_epoch" => { "type" => "string" },
          "persist_as_memory" => { "type" => "boolean",
                                   "description" => "Writes a task_checkpoint memory revision in the same " \
                                                    "transaction through the same Remember path." },
          "receipt_id" => { "type" => "string", "minLength" => 1,
                            "description" => "A still-applicable assessment receipt from op=assess." },
          "expected_heads" => expected_heads,
          "closing_note" => { "type" => "string" },
          "limitations_acknowledged" => common.string_array("Limitations the closer acknowledges.")
        }
      end

      def expected_heads
        { "type" => "object", "additionalProperties" => false, "minProperties" => 1,
          "description" => "Heads as the caller observed them. A mismatch returns " \
                           "kioku.precondition_failed with the concrete difference, never a partial close.",
          "properties" => HEAD_NAMES.to_h { |name| [name, { "type" => "integer", "minimum" => 0 }] } }
      end
    end
  end
end
