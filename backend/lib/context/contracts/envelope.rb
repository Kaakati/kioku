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
      SCHEMA_VERSION = "kioku.tool.v1"
      DEADLINE_MS_RANGE = (1..30_000).freeze
      REQUEST_DIGEST = /\Asha256:[0-9a-f]{64}\z/
      MAX_IDEMPOTENCY_KEY_BYTES = 128

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
