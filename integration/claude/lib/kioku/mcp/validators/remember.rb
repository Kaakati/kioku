# frozen_string_literal: true

require_relative "../rules"
require_relative "../tool_contract"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_remember].
      #
      # The accepted surface is the published one, so D7's whole class of defect is gone:
      # memory_key, lifecycle and mandatory are contract-named inputs the core already
      # takes, and a PERMITTED list that omitted them made `envelope.expected_revision`
      # unreachable, kioku.authority_violation unprovokeable, and CLAUDE.md's first
      # implementation slice — a shared preference plus one project exception —
      # unbuildable.
      #
      # A save records a conclusion; it never establishes support. claim_support and
      # authority are core-derived and are declared nowhere in the artifact's request
      # surface, so closure refuses them at whatever depth a caller nests them.
      class Remember
        CONTRACT = ToolContract.new("context_remember")

        def call(arguments:)
          CONTRACT.call(arguments: arguments, mutation: true) do
            refuse_without_evidence(arguments)
            refuse_unbound_destination(arguments)
          end
        end

        private

        # "the core ... rejects the write with kioku.evidence_required if none is
        # eligible" [contracts: tools context_remember x-kioku-refusals]. A caller
        # branches on this differently from kioku.invalid_request: it must add evidence,
        # not fix its request.
        def refuse_without_evidence(arguments)
          entries = arguments["evidence"]
          return unless entries.is_a?(Array) && entries.empty?

          raise Kioku::Error.new("kioku.evidence_required",
                                 message: "an explicit memory write carries at least one evidence link")
        end

        # "An absent or ambiguous project binding returns kioku.project_binding_unresolved;
        # it is never read as permission to write globally"
        # [contracts: tools context_remember].
        def refuse_unbound_destination(arguments)
          destination = arguments["destination"]
          return unless destination.is_a?(Hash) && destination["store_kind"] == "project"

          key = destination["project_key"]
          return if key.is_a?(String) && !key.strip.empty?

          raise Kioku::Error.new("kioku.project_binding_unresolved",
                                 message: "a project memory names no bound project",
                                 details: { "setup_required" => true })
        end
      end
    end
  end
end
