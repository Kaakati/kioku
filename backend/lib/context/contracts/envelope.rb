# frozen_string_literal: true

module Context
  module Contracts
    # The common envelope every tool call carries (plan 6.1). Mutations
    # additionally carry an actor-scoped idempotency key, a request digest and
    # an expected revision where applicable.
    #
    # This is a value type only. Decoding a wire payload into it — and refusing
    # the payloads the contract refuses — is EnvelopeDecoder's job.
    class Envelope
      # The version this core IMPLEMENTS. A response carries it, never an echo of the
      # caller's declared minor: the core does not claim to implement a minor it does not
      # [contracts: contract.json minor_policy.response_version].
      #
      # The deadline range, the digest pattern and the idempotency-key bound used to be
      # restated here and checked by hand. They are declared in the artifact's envelope
      # schema and enforced by the structural pass, so a copy of them in Ruby would only
      # ever be a second opinion.
      SCHEMA_VERSION = Contracts.contract.fetch("implemented_version")

      attr_reader :schema_version, :request_id, :deadline_ms, :scope,
                  :idempotency_key, :request_digest, :expected_revision

      def initialize(schema_version:, request_id:, deadline_ms:, scope:,
                     idempotency_key: nil, request_digest: nil, expected_revision: nil)
        @schema_version = schema_version
        @request_id = request_id
        @deadline_ms = deadline_ms
        @scope = scope
        @idempotency_key = idempotency_key
        @request_digest = request_digest
        @expected_revision = expected_revision
        freeze
      end

      # A relative budget, not an absolute timestamp: host and container clocks
      # are not assumed synchronized. The core computes the absolute deadline.
      def deadline_at(from)
        from + (deadline_ms / 1000.0)
      end
    end
  end
end
