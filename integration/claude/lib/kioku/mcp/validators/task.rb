# frozen_string_literal: true

require_relative "../rules"
require_relative "../tool_contract"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_task; task_operations[]]. The eight operations are a
      # discriminated union, not an envelope around arbitrary content: each branch
      # declares the fields it accepts, so a field belonging to another operation, or a
      # free-form payload, is refused rather than carried along.
      #
      # Which operations are reads is read from the union itself — a branch whose
      # envelope requires an idempotency key is a mutation — so the seven mutating
      # operations cannot drift from the seven the artifact publishes.
      class Task
        CONTRACT = ToolContract.new("context_task")

        def call(arguments:)
          Rules.invalid!("the tool arguments must be an object") unless arguments.is_a?(Hash)
          op = operation(arguments)

          CONTRACT.call(arguments: arguments, mutation: mutation?(op))
        end

        private

        # "Covers unknown context_task op" [contracts: errors kioku.unsupported_operation].
        # An absent op is a different fault: nothing was declared, so nothing is
        # unsupported, and the union's own refusal names it.
        def operation(arguments)
          declared = arguments["op"]
          return nil unless declared.is_a?(String)
          return declared if Kioku::Contracts.definition("task_op").fetch("enum").include?(declared)

          Rules.unsupported!("the requested task operation is not one of the eight frozen operations",
                             "fields" => ["op"])
        end

        def mutation?(op)
          branch = CONTRACT.declares("oneOf")&.find { |alternative| Rules.at(alternative, "properties", "op", "const") == op }

          Array(Rules.at(branch, "properties", "envelope", "required")).include?("idempotency_key")
        end
      end
    end
  end
end
