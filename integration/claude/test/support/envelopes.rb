# frozen_string_literal: true

module Kioku
  module TestSupport
    # Builders for the frozen kioku.tool.v1 envelope [contracts: envelope.request_fields].
    module Envelopes
      SCHEMA_VERSION = "kioku.tool.v1"
      PROJECT_KEY = "kioku"

      # "sha256:" + 64 lowercase hex [contracts: request_fields.request_digest].
      def valid_request_digest(seed = "red-phase")
        "sha256:#{Digest::SHA256.hexdigest(seed)}"
      end

      # UUIDv7, 36 characters [contracts: request_fields.request_id].
      def uuid_v7
        hex = SecureRandom.hex(16)
        hex[12] = "7"
        hex[16] = "9"
        "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
      end

      def read_envelope(overrides = {})
        {
          "schema_version" => SCHEMA_VERSION,
          "request_id" => uuid_v7,
          "deadline_ms" => 3_000,
          "scope" => { "store" => "project", "project_key" => PROJECT_KEY }
        }.merge(overrides)
      end

      def mutation_envelope(overrides = {})
        read_envelope(
          "idempotency_key" => "idem-#{SecureRandom.hex(8)}",
          "request_digest" => valid_request_digest(SecureRandom.hex(4))
        ).merge(overrides)
      end

      def generation_vector
        {
          "canonical_generation" => 12,
          "policy_generation" => 3,
          "global_generation" => 4,
          "index_generation" => 9,
          "source_epoch" => 7,
          "deletion_epoch" => 1,
          "host_link_state" => "connected",
          "observed_at" => "2026-09-15T10:00:00Z"
        }
      end

      # A response that satisfies every "required: true" field
      # [contracts: envelope.response_fields].
      def success_response(overrides = {})
        {
          "schema_version" => SCHEMA_VERSION,
          "request_id" => uuid_v7,
          "status" => "success",
          "error" => nil,
          "data" => { "items" => [] },
          "generation_vector" => generation_vector,
          "coverage" => { "state" => "complete_for_declared_set" },
          "limits" => {
            "deadline_at" => "2026-09-15T10:00:03Z",
            "elapsed_ms" => 11,
            "returned" => 0,
            "truncated" => false
          },
          "warnings" => [],
          "server_time" => "2026-09-15T10:00:00Z"
        }.merge(overrides)
      end

      def error_body(code, overrides = {})
        {
          "code" => code,
          "message" => "operator facing message",
          "retryable" => false,
          "retry_after_ms" => nil,
          "details" => {}
        }.merge(overrides)
      end
    end
  end
end
