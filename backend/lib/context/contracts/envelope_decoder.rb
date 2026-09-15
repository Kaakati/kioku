# frozen_string_literal: true

module Context
  module Contracts
    # Decodes an untrusted wire payload into an Envelope, refusing what the shared
    # contract refuses.
    #
    # Every tool arrives as a POST whether it reads or mutates, so the caller declares
    # which it is; the idempotency fields are required only for a mutation.
    #
    # The hand-written field checks this replaced had drifted three ways from the host
    # that sends them: it demanded string equality with "kioku.tool.v1" and so refused
    # every additive minor release (D2), it accepted any non-blank request_id where the
    # contract names a UUIDv7 (D3), and it closed nothing, so an identity field nested
    # one level deeper than BaseController's name list reached it unrefused (D6). The
    # structural pass now runs against the artifact's own envelope schema, which is the
    # same document the host validates against.
    #
    # Two refusals stay hand-written because no schema can express them, and the artifact
    # records which condition maps to which wire name
    # [contracts: envelope.request x-kioku-refusals].
    class EnvelopeDecoder
      OPERATIONS = %i[read mutation].freeze
      BASE_POINTER = "/envelope"

      # The contract freezes the SUPPORTED pattern only. This one exists for a single
      # purpose: telling a declared contract version this core does not implement —
      # another major, or another contract family — which is
      # kioku.unsupported_schema_version, from a string that names no version at all,
      # which is kioku.invalid_request.
      VERSIONED_CONTRACT = /\A[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*\.v\d+(?:\.(?:0|[1-9][0-9]*))?\z/

      def initialize(operation:)
        raise ArgumentError, "unknown operation #{operation.inspect}" unless OPERATIONS.include?(operation)

        @operation = operation
      end

      def call(payload)
        invalid!("envelope") unless payload.is_a?(Hash)
        version = schema_version(payload)
        validator.validate!(payload)

        Envelope.new(schema_version: version, request_id: payload["request_id"],
                     deadline_ms: payload["deadline_ms"], scope: scope(payload["scope"]),
                     **mutation_fields(payload))
      end

      private

      attr_reader :operation

      def validator
        @validator ||= SchemaValidator.new(Contracts.envelope_schema(operation), base: BASE_POINTER)
      end

      # D2. "Rejected with kioku.unsupported_schema_version if the major does not match a
      # supported contract. Minor additions are additive-only." Exact equality made every
      # additive release breaking; accepting an unknown minor widens nothing, because a
      # field a later minor adds is still refused by the closure rule below.
      #
      # A response carries the version this core IMPLEMENTS, never an echo of the
      # caller's declared minor: the core does not claim to implement a minor it does not.
      def schema_version(wire)
        declared = wire["schema_version"]
        invalid!("schema_version") unless declared.is_a?(String)
        return Envelope::SCHEMA_VERSION if Contracts.schema_version_pattern.match?(declared)

        invalid!("schema_version") unless VERSIONED_CONTRACT.match?(declared)
        raise Errors::UnsupportedSchemaVersion.new(
          "this core implements #{Envelope::SCHEMA_VERSION}",
          details: { supported: [Envelope::SCHEMA_VERSION] }
        )
      end

      # The structural pass has already closed the object and checked `store` against the
      # declared enum, so what is left is the one condition the schema cannot state.
      def scope(raw)
        store = raw["store"]
        project_key = presence(raw["project_key"])
        scope = Scope.new(store: store.to_sym, project_key: project_key)
        binding_unresolved! if scope.project? && project_key.nil?
        scope
      end

      def mutation_fields(wire)
        return {} unless operation == :mutation

        { idempotency_key: presence(wire["idempotency_key"]),
          request_digest: wire["request_digest"],
          expected_revision: wire["expected_revision"] }
      end

      def presence(value)
        return nil unless value.is_a?(String)

        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      def invalid!(field)
        pointer = "#{BASE_POINTER}/#{field}"
        raise Errors::InvalidRequest.new(
          "the request envelope failed contract validation: #{pointer} is required",
          details: { fields: [pointer] }
        )
      end

      # Invariant 11: a missing project binding is surfaced as setup state and is never
      # read as permission to write or read globally.
      def binding_unresolved!
        raise Errors::ProjectBindingUnresolved.new(
          "no project binding was supplied for a project scoped request",
          details: { setup_required: true }
        )
      end
    end
  end
end
