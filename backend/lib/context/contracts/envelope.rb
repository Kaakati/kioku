# frozen_string_literal: true

module Context
  module Contracts
    # The common request envelope shared by all six tools and by the HTTP/UI
    # surface (Plan §6.1).
    class Envelope < Data.define(
      :schema_version,
      :request_id,
      :deadline,
      :scope,
      :idempotency_key,
      :request_digest,
      :expected_revision,
      :token_budget,
      :correlation,
      :client,
      :trace_id
    )
      FIELDS = %w[
        schema_version request_id deadline_ms scope idempotency_key request_digest
        expected_revision token_budget correlation client trace_id
      ].freeze

      SUPPORTED_MAJOR = "kioku.tool.v1"

      def initialize(schema_version:, request_id:, deadline:, scope:, idempotency_key: nil,
                     request_digest: nil, expected_revision: nil, token_budget: nil,
                     correlation: {}, client: nil, trace_id: nil)
        super
      end

      # mutation: true additionally requires the actor-scoped idempotency key
      # and request digest.
      def self.parse(payload, tool:, mutation:, op: nil, started_at: Time.now.utc)
        body = Validator.hash!(Validator.deep_stringify(payload), field: "envelope")
        # Core-derived fields are checked first: "you may not set authority" is
        # a more useful answer than "unknown field".
        Validator.reject_core_derived!(body, field: "envelope")
        Validator.reject_unknown!(body, allowed: FIELDS, field: "envelope")
        check_schema_version!(body["schema_version"])
        new(**base_attributes(body, tool, op, started_at).merge(mutation_attributes(body, mutation)))
      end

      # Rejected before any scope resolution, so no generation vector is
      # available to accompany it. Minor additions are additive-only.
      def self.check_schema_version!(value)
        raise Errors::UnsupportedSchemaVersion.new(details: { supplied: nil }) unless value.is_a?(String)

        supported = value == SUPPORTED_MAJOR || value.start_with?("#{SUPPORTED_MAJOR}.")
        raise Errors::UnsupportedSchemaVersion.new(details: { supported: SUPPORTED_MAJOR }) unless supported

        value
      end

      def self.base_attributes(body, tool, op, started_at)
        {
          schema_version: body["schema_version"],
          request_id: Validator.pattern!(Validator.required(body, "request_id", field: "envelope.request_id"),
                                         field: "envelope.request_id", pattern: request_id_pattern),
          deadline: Deadline.for(tool: tool, op: op, requested_ms: Validator.required(body, "deadline_ms", field: "envelope.deadline_ms"),
                                 started_at: started_at),
          scope: Scope.parse(Validator.required(body, "scope", field: "envelope.scope")),
          expected_revision: optional_revision(body["expected_revision"]),
          token_budget: optional_budget(body["token_budget"]),
          correlation: parse_correlation(body["correlation"]),
          client: parse_client(body["client"]),
          trace_id: body["trace_id"] && Validator.string!(body["trace_id"], field: "envelope.trace_id", max: 128)
        }
      end

      def self.mutation_attributes(body, mutation)
        return { idempotency_key: nil, request_digest: nil } unless mutation

        {
          idempotency_key: Validator.string!(Validator.required(body, "idempotency_key", field: "envelope.idempotency_key"),
                                             field: "envelope.idempotency_key", max: 128),
          request_digest: Validator.pattern!(Validator.required(body, "request_digest", field: "envelope.request_digest"),
                                             field: "envelope.request_digest", pattern: request_digest_pattern)
        }
      end

      def self.request_id_pattern = SchemaRegistry.dig!("envelope", "$defs", "request_id", "pattern")
      def self.request_digest_pattern = SchemaRegistry.dig!("envelope", "$defs", "request_digest", "pattern")

      def self.optional_revision(value)
        value.nil? ? nil : Validator.integer!(value, field: "envelope.expected_revision", min: 1, max: 2**62)
      end

      def self.optional_budget(value)
        value.nil? ? nil : Validator.integer!(value, field: "envelope.token_budget", min: 1, max: 1_000_000)
      end

      def self.parse_correlation(value)
        return {} if value.nil?

        allowed = SchemaRegistry.dig!("envelope", "$defs", "correlation", "properties").keys
        Validator.reject_unknown!(Validator.hash!(value, field: "envelope.correlation"),
                                  allowed: allowed, field: "envelope.correlation").freeze
      end

      def self.parse_client(value)
        return nil if value.nil?

        body = Validator.hash!(value, field: "envelope.client")
        {
          "name" => Validator.string!(Validator.required(body, "name", field: "envelope.client.name"), field: "envelope.client.name", max: 128),
          "version" => Validator.string!(Validator.required(body, "version", field: "envelope.client.version"), field: "envelope.client.version", max: 64)
        }.freeze
      end

      private_class_method :base_attributes, :mutation_attributes, :optional_revision,
                           :optional_budget, :parse_correlation, :parse_client

      def mutation? = !idempotency_key.nil?
      def creating? = expected_revision.nil?
    end
  end
end
