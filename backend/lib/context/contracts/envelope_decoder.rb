# frozen_string_literal: true

module Context
  module Contracts
    # Decodes an untrusted wire payload into an Envelope, refusing what the
    # frozen contract refuses.
    #
    # Every tool arrives as a POST whether it reads or mutates, so the caller
    # declares which it is; the idempotency fields are required only for a
    # mutation. Fields are validated in contract order, so an unsupported schema
    # version is reported before any scope resolution.
    class EnvelopeDecoder
      OPERATIONS = %i[read mutation].freeze

      def initialize(operation:)
        raise ArgumentError, "unknown operation #{operation.inspect}" unless OPERATIONS.include?(operation)

        @operation = operation
      end

      def call(payload)
        wire = payload.is_a?(Hash) ? payload : invalid!("envelope")
        Envelope.new(
          schema_version: schema_version(wire),
          request_id: request_id(wire),
          deadline_ms: deadline_ms(wire),
          scope: scope(wire),
          **mutation_fields(wire)
        )
      end

      private

      attr_reader :operation

      def schema_version(wire)
        value = wire["schema_version"]
        invalid!("schema_version") if value.nil? || value.to_s.strip.empty?
        return value if value == Envelope::SCHEMA_VERSION

        raise Errors::UnsupportedSchemaVersion.new(
          "this core implements #{Envelope::SCHEMA_VERSION}",
          details: { supported: [Envelope::SCHEMA_VERSION] }
        )
      end

      def request_id(wire)
        value = wire["request_id"]
        invalid!("request_id") if value.nil? || value.to_s.strip.empty?
        value
      end

      def deadline_ms(wire)
        value = wire["deadline_ms"]
        invalid!("deadline_ms") unless value.is_a?(Integer) && Envelope::DEADLINE_MS_RANGE.cover?(value)
        value
      end

      def scope(wire)
        raw = wire["scope"]
        invalid!("scope") unless raw.is_a?(Hash)
        store = raw["store"].to_s
        invalid!("scope.store") unless Scope::STORES.map(&:to_s).include?(store)

        scope = Scope.new(store: store.to_sym, project_key: presence(raw["project_key"]))
        binding_unresolved! if scope.project? && scope.project_key.nil?
        scope
      end

      def mutation_fields(wire)
        return {} unless operation == :mutation

        {
          idempotency_key: idempotency_key(wire),
          request_digest: request_digest(wire),
          expected_revision: expected_revision(wire)
        }
      end

      def idempotency_key(wire)
        value = presence(wire["idempotency_key"])
        invalid!("idempotency_key") if value.nil? || value.bytesize > Envelope::MAX_IDEMPOTENCY_KEY_BYTES
        value
      end

      def request_digest(wire)
        value = wire["request_digest"].to_s
        invalid!("request_digest") unless Envelope::REQUEST_DIGEST.match?(value)
        value
      end

      def expected_revision(wire)
        value = wire["expected_revision"]
        return nil if value.nil?

        invalid!("expected_revision") unless value.is_a?(Integer) && value >= 1
        value
      end

      def presence(value)
        return nil unless value.is_a?(String)

        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      def invalid!(field)
        raise Errors::InvalidRequest.new(
          "the request envelope failed contract validation",
          details: { fields: [field] }
        )
      end

      # Invariant 11: a missing project binding is surfaced as setup state and is
      # never read as permission to write or read globally.
      def binding_unresolved!
        raise Errors::ProjectBindingUnresolved.new(
          "no project binding was supplied for a project scoped request",
          details: { setup_required: true }
        )
      end
    end
  end
end
