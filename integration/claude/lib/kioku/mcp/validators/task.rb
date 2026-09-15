# frozen_string_literal: true

require_relative "../rules"
require_relative "../vocabulary"
require_relative "task_operations"
require_relative "../../envelope"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_task; task_operations[]]. The eight operations are a
      # discriminated union, not an envelope around arbitrary content: each operation
      # declares the fields it accepts, so a field belonging to another operation, or a
      # free-form payload, is refused rather than carried along.
      class Task
        COMMON_FIELDS = %w[envelope op].freeze

        OP_FIELDS = {
          "get" => %w[task_key],
          "set_contract" => %w[task_key objective scope criteria origin_event_ref],
          "record_claim" => %w[task_key contract_revision statement materiality subjects assessment],
          "propose" => %w[task_key contract_revision proposal],
          "plan_check" => %w[task_key contract_revision criterion_key check_kind expected_snapshot_ref
                             expected_environment_fingerprint verifier_digest minimum_input_assurance
                             definition],
          "assess" => %w[task_key expected_contract_revision criterion_keys],
          "checkpoint" => %w[task_key contract_revision state summary],
          "close" => %w[task_key expected_contract_revision receipt_id expected_heads]
        }.freeze

        REQUIRED_FIELDS = {
          "get" => %w[task_key],
          "set_contract" => %w[objective scope criteria origin_event_ref],
          "record_claim" => %w[task_key contract_revision statement materiality subjects],
          "propose" => %w[task_key contract_revision proposal],
          "plan_check" => %w[task_key contract_revision criterion_key check_kind expected_snapshot_ref
                             expected_environment_fingerprint verifier_digest minimum_input_assurance
                             definition],
          "assess" => %w[task_key expected_contract_revision],
          "checkpoint" => %w[task_key contract_revision state summary],
          "close" => %w[task_key expected_contract_revision receipt_id expected_heads]
        }.freeze

        READ_OPERATIONS = %w[get].freeze

        def call(arguments:)
          op = operation(arguments)
          Rules.only(arguments, COMMON_FIELDS + OP_FIELDS.fetch(op))
          envelope = Kioku::Envelope.parse_request(arguments["envelope"],
                                                   mutation: !READ_OPERATIONS.include?(op))
          Rules.require_keys(arguments, REQUIRED_FIELDS.fetch(op))
          TaskOperations.new.call(op: op, arguments: arguments)
          envelope
        end

        private

        # "Covers unknown context_task op" [contracts: errors kioku.unsupported_operation].
        def operation(arguments)
          declared = arguments["op"]
          Rules.invalid!("op is required and discriminates the eight task operations") unless
            declared.is_a?(String)
          return declared if Vocabulary::TASK_OPERATIONS.include?(declared)

          Rules.unsupported!("the requested task operation is not one of the eight frozen operations",
                             "op" => declared)
        end
      end
    end
  end
end
