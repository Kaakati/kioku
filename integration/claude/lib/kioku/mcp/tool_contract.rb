# frozen_string_literal: true

require_relative "rules"
require_relative "../contracts"
require_relative "../contracts/schema"
require_relative "../envelope"
require_relative "../request_digest"

module Kioku
  module Mcp
    # One tool's accepted surface, taken from the shared artifact.
    #
    # The published MCP inputSchema and the surface this package accepts are the same
    # object — `conformance/resolved_tools.json` — so a model can no longer be shown one
    # contract and validated against another. That is what D7 was: PERMITTED = %w[envelope
    # kind destination title body evidence applicability] refused memory_key, lifecycle,
    # mandatory and nine more inputs the contract names, and the published schema omitted
    # them too, so `expected_revision` had nothing it could apply to.
    #
    # The order below is the contract's validation order, and each step exists because a
    # later one would otherwise answer with the wrong wire name:
    #
    #   1. the envelope, so an unsupported MAJOR is kioku.unsupported_schema_version
    #      rather than a pattern failure, and before any scope work;
    #   2. contract-named inputs this build has not implemented, so they are refused BY
    #      NAME with kioku.unsupported_operation rather than as unknown fields — a caller
    #      must never believe an override was recorded, and never be told its request was
    #      malformed when it was exactly what the contract names;
    #   3. the tool's own refusals, which carry codes no schema can express
    #      (kioku.evidence_required, kioku.project_binding_unresolved);
    #   4. the structural pass, which closes every object at every depth;
    #   5. the request digest, RECOMPUTED over the body it arrived with.
    class ToolContract
      NOT_IMPLEMENTED = Kioku::Contracts.contract.fetch("not_yet_implemented")
                                        .fetch("details").fetch("reason")

      def initialize(tool)
        @tool = tool
      end

      def call(arguments:, mutation:)
        Rules.invalid!("the tool arguments must be an object") unless arguments.is_a?(Hash)
        envelope = Kioku::Envelope.parse_request(arguments["envelope"], mutation: mutation)
        refuse_unimplemented!(arguments)
        yield if block_given?
        schema.validate!(arguments)
        verify_digest!(arguments, envelope)
        envelope
      end

      # A bound or an enum the tool's own refusals need, read from the published schema
      # rather than restated in Ruby.
      def declares(*path)
        Kioku::Contracts.tool_schema(@tool).dig(*path)
      end

      private

      def schema
        @schema ||= Kioku::Contracts::Schema.new(Kioku::Contracts.tool_schema(@tool))
      end

      # "It is never silently dropped: a caller must not believe an override, a link or
      # an attempt record was stored when nothing was"
      # [contracts: contract.json not_yet_implemented].
      def refuse_unimplemented!(arguments)
        supplied = Kioku::Contracts.unimplemented(@tool) & arguments.keys
        return if supplied.empty?

        raise Kioku::Error.new(
          "kioku.unsupported_operation",
          message: "this build does not implement: #{supplied.sort.join(', ')}",
          details: { "reason" => NOT_IMPLEMENTED, "fields" => supplied.sort }
        )
      end

      # E1. "The core RECOMPUTES the digest over the received body and compares it to the
      # asserted value. A caller-asserted digest never decides a durability claim"
      # [contracts: contract.json request_digest.authority].
      #
      # Without this the asserted string travels to the core untouched, and a reused
      # idempotency key carrying a stale digest replays a receipt for content nobody
      # sent — a caller-asserted fact deciding whether a write happened.
      def verify_digest!(arguments, envelope)
        asserted = envelope.request_digest
        return if asserted.nil? || Kioku::RequestDigest.compute(arguments) == asserted

        Rules.invalid!("the asserted request_digest does not describe the body it arrived with",
                       "fields" => ["request_digest"])
      end
    end
  end
end
