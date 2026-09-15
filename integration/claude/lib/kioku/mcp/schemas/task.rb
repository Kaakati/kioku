# frozen_string_literal: true

require_relative "shared"

module Kioku
  module Mcp
    module Schemas
      # "a discriminated eight-operation schema that is not an arbitrary command or SQL
      # interface" [contracts: tools context_task].
      #
      # JSON Schema publishes the union of the eight operations' fields; `op` is the
      # discriminator and the host enforces each operation's own required and permitted
      # set, so a field belonging to another operation is refused rather than ignored.
      module Task
        module_function

        def schema
          Shared.closed_object(%w[envelope op], properties)
        end

        def properties
          { "envelope" => Shared.envelope,
            "op" => Shared.enum(Vocabulary::TASK_OPERATIONS),
            "task_key" => Shared.string }
            .merge(contract_fields).merge(claim_fields).merge(check_fields).merge(closing_fields)
        end

        def contract_fields
          { "objective" => Shared.string,
            "scope" => Shared.object(%w[project_key],
                                     "project_key" => Shared.string,
                                     "repository_keys" => Shared.string_list,
                                     "worktree_keys" => Shared.string_list),
            "criteria" => { "type" => "array", "items" => criterion },
            "origin_event_ref" => Shared.string,
            "contract_revision" => revision,
            "expected_contract_revision" => revision }
        end

        def claim_fields
          { "statement" => Shared.string,
            "materiality" => Shared.enum(Vocabulary::CLAIM_MATERIALITY),
            "subjects" => Shared.array(Shared.typed_handle, min: 1, max: 50),
            "assessment" => assessment,
            "proposal" => proposal }
        end

        def check_fields
          { "criterion_key" => Shared.string,
            "criterion_keys" => Shared.string_list,
            "check_kind" => Shared.enum(Vocabulary::CHECK_KINDS),
            "expected_snapshot_ref" => Shared.string,
            "expected_environment_fingerprint" => Shared.string,
            "verifier_digest" => Shared.string,
            "minimum_input_assurance" => Shared.enum(Vocabulary::INPUT_ASSURANCE_LEVELS),
            "definition" => { "type" => "object", "minProperties" => 1 } }
        end

        def closing_fields
          { "state" => Shared.enum(Vocabulary::CHECKPOINT_STATES),
            "summary" => Shared.string,
            "receipt_id" => Shared.string,
            "expected_heads" => { "type" => "object", "minProperties" => 1 } }
        end

        def revision
          { "type" => "integer", "minimum" => 1 }
        end

        def criterion
          Shared.object(%w[criterion_key description required authority verification_policy],
                        "criterion_key" => Shared.string,
                        "description" => Shared.string,
                        "required" => { "type" => "boolean" },
                        "authority" => Shared.enum(Vocabulary::CRITERION_AUTHORITIES),
                        "verification_policy" => { "type" => "object", "minProperties" => 1 })
        end

        # "an assessment supplied by a model actor is recorded as an attributed judgment
        # with its evaluator, never as a verified fact"
        # [contracts: task_operations record_claim].
        def assessment
          Shared.object(%w[support evaluator],
                        "support" => Shared.enum(Vocabulary::CLAIM_SUPPORT),
                        "evaluator" => Shared.string,
                        "rationale" => Shared.string)
        end

        def proposal
          Shared.object(Vocabulary::PROPOSAL_FIELDS,
                        "problem" => Shared.string,
                        "mechanism" => Shared.string,
                        "expected_effect" => Shared.string,
                        "preconditions" => { "type" => "array", "items" => precondition },
                        "change_scope" => Shared.array(Shared.typed_handle, min: 1, max: 50),
                        "discriminating_check" => Shared.string)
        end

        def precondition
          Shared.object(%w[kind detail],
                        "kind" => Shared.enum(Vocabulary::PRECONDITION_KINDS),
                        "detail" => Shared.string)
        end
      end
    end
  end
end

