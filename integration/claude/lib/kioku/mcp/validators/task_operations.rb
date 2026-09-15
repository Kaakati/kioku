# frozen_string_literal: true

require_relative "../rules"
require_relative "../vocabulary"

module Kioku
  module Mcp
    module Validators
      # Per-operation field validation for context_task [contracts: task_operations[]].
      #
      # The operation has already been discriminated and its accepted field set enforced;
      # this checks the shape of what each operation requires.
      class TaskOperations
        MAX_KEY = 512
        MAX_TEXT = 4096

        def call(op:, arguments:)
          # `op` has already been constrained to the eight frozen operations.
          send(:"validate_#{op}", arguments)
        end

        private

        def validate_get(arguments)
          Rules.text(arguments, "task_key", max: MAX_KEY)
        end

        def validate_set_contract(arguments)
          Rules.text(arguments, "objective", max: MAX_TEXT)
          Rules.text(Rules.object(arguments, "scope"), "project_key", max: MAX_KEY)
          validate_criteria(arguments)
          Rules.text(arguments, "origin_event_ref", max: MAX_KEY)
        end

        # "an empty criteria list is legal and leaves the task unassessable, never
        # vacuously complete" [contracts: task_operations set_contract].
        def validate_criteria(arguments)
          criteria = arguments["criteria"]
          Rules.invalid!("criteria must be an array") unless criteria.is_a?(Array)
          criteria.each_with_index do |criterion, index|
            Rules.invalid!("criteria[#{index}] must be an object") unless criterion.is_a?(Hash)
            Rules.text(criterion, "description", max: MAX_TEXT)
            Rules.enum(criterion, "authority", Vocabulary::CRITERION_AUTHORITIES)
          end
        end

        def validate_record_claim(arguments)
          Rules.text(arguments, "task_key", max: MAX_KEY)
          Rules.integer(arguments, "contract_revision", minimum: 1)
          Rules.text(arguments, "statement", max: MAX_TEXT)
          Rules.enum(arguments, "materiality", Vocabulary::CLAIM_MATERIALITY)
          Rules.typed_handles(arguments, "subjects", min: 1, max: 50)
          validate_assessment(arguments)
        end

        # "an assessment supplied by a model actor is recorded as an attributed judgment
        # with its evaluator, never as a verified fact"
        # [contracts: task_operations record_claim].
        def validate_assessment(arguments)
          assessment = arguments["assessment"]
          return if assessment.nil?

          Rules.invalid!("assessment must be an object") unless assessment.is_a?(Hash)
          Rules.enum(assessment, "support", Vocabulary::CLAIM_SUPPORT)
          Rules.text(assessment, "evaluator", max: MAX_KEY)
        end

        def validate_propose(arguments)
          Rules.text(arguments, "task_key", max: MAX_KEY)
          Rules.integer(arguments, "contract_revision", minimum: 1)
          proposal = Rules.object(arguments, "proposal")
          Rules.require_keys(proposal, Vocabulary::PROPOSAL_FIELDS)
          Rules.text(proposal, "discriminating_check", max: MAX_TEXT)
        end

        # "planning a check confers no execution permission" and check identity is
        # immutable, so every input that fixes that identity is required
        # [contracts: task_operations plan_check].
        def validate_plan_check(arguments)
          Rules.text(arguments, "task_key", max: MAX_KEY)
          Rules.integer(arguments, "contract_revision", minimum: 1)
          Rules.text(arguments, "criterion_key", max: MAX_KEY)
          Rules.enum(arguments, "check_kind", Vocabulary::CHECK_KINDS)
          Rules.text(arguments, "expected_snapshot_ref", max: MAX_KEY)
          Rules.text(arguments, "expected_environment_fingerprint", max: MAX_KEY)
          Rules.text(arguments, "verifier_digest", max: MAX_KEY)
          Rules.enum(arguments, "minimum_input_assurance", Vocabulary::INPUT_ASSURANCE_LEVELS)
          Rules.object(arguments, "definition")
        end

        def validate_assess(arguments)
          Rules.text(arguments, "task_key", max: MAX_KEY)
          Rules.integer(arguments, "expected_contract_revision", minimum: 1)
        end

        def validate_checkpoint(arguments)
          Rules.text(arguments, "task_key", max: MAX_KEY)
          Rules.integer(arguments, "contract_revision", minimum: 1)
          Rules.enum(arguments, "state", Vocabulary::CHECKPOINT_STATES)
          Rules.text(arguments, "summary", max: MAX_TEXT)
        end

        def validate_close(arguments)
          Rules.text(arguments, "task_key", max: MAX_KEY)
          Rules.integer(arguments, "expected_contract_revision", minimum: 1)
          Rules.text(arguments, "receipt_id", max: MAX_KEY)
          heads = Rules.object(arguments, "expected_heads")
          Rules.invalid!("expected_heads must name the heads the caller observed") if heads.empty?
        end
      end
    end
  end
end
