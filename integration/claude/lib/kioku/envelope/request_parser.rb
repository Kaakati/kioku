# frozen_string_literal: true

require_relative "refusals"
require_relative "schema_version"

module Kioku
  module Envelope
    Scope = Struct.new(:store, :project_key, :cross_project_keys, keyword_init: true)

    Request = Struct.new(:schema_major, :request_id, :deadline_ms, :scope,
                         :idempotency_key, :request_digest, :expected_revision, :payload,
                         keyword_init: true)

    # Parses the common request envelope [contracts: envelope.request_fields].
    class RequestParser
      include Refusals

      UUID_V7 = /\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      REQUEST_DIGEST = /\Asha256:[0-9a-f]{64}\z/
      STORES = %w[project global both].freeze
      DEADLINE_RANGE = (1..30_000).freeze
      MAX_IDEMPOTENCY_KEY_LENGTH = 128

      # "Derived by the core from origin_role and transport, never accepted from the
      # caller" [contracts: labels.authority; envelope.transport_and_actor.actor_identity].
      CORE_DERIVED_FIELDS = %w[actor_principal_id authority origin_role].freeze

      def initialize(mutation: false)
        @mutation = mutation
      end

      def call(payload:)
        invalid!("the envelope must be an object") unless payload.is_a?(Hash)
        major = SchemaVersion.new.call(declared: payload["schema_version"])
        reject_core_derived_fields(payload)

        Request.new(schema_major: major, request_id: request_id(payload),
                    deadline_ms: deadline_ms(payload), scope: scope(payload["scope"]),
                    idempotency_key: idempotency_key(payload), request_digest: request_digest(payload),
                    expected_revision: expected_revision(payload), payload: payload)
      end

      private

      def reject_core_derived_fields(payload)
        supplied = CORE_DERIVED_FIELDS & payload.keys
        return if supplied.empty?

        invalid!("core-derived fields cannot be supplied by a caller: #{supplied.sort.join(', ')}")
      end

      def request_id(payload)
        value = payload["request_id"]
        invalid!("request_id is required") unless value.is_a?(String)
        invalid!("request_id must be a 36 character UUIDv7") unless value.length == 36 && UUID_V7.match?(value)
        value
      end

      def deadline_ms(payload)
        value = payload["deadline_ms"]
        invalid!("deadline_ms must be an integer millisecond budget") unless value.is_a?(Integer)
        invalid!("deadline_ms must fall within #{DEADLINE_RANGE}") unless DEADLINE_RANGE.cover?(value)
        value
      end

      def scope(raw)
        invalid!("scope is required") unless raw.is_a?(Hash)
        store = raw["store"]
        invalid!("scope.store must be one of #{STORES.join(', ')}") unless STORES.include?(store)
        project_key = store == "global" ? nil : bound_project_key(raw["project_key"])

        Scope.new(store: store, project_key: project_key, cross_project_keys: cross_project_keys(raw))
      end

      # "A missing or ambiguous binding returns kioku.project_binding_unresolved and must
      # never fall back to global" [contracts: request_fields.scope.project_key].
      def bound_project_key(value)
        return value if value.is_a?(String) && !value.strip.empty?

        raise Kioku::Error.new("kioku.project_binding_unresolved",
                               message: "the request declares a project store without a bound project",
                               details: { "setup_required" => true })
      end

      def cross_project_keys(raw)
        value = raw["cross_project_keys"]
        return [] if value.nil?
        invalid!("scope.cross_project_keys must be an array of keys") unless array_of_strings?(value)
        value
      end

      def array_of_strings?(value)
        value.is_a?(Array) && value.all?(String)
      end

      def idempotency_key(payload)
        return nil unless @mutation

        value = payload["idempotency_key"]
        invalid!("a mutation requires an actor-scoped idempotency_key") unless present_string?(value)
        invalid!("idempotency_key exceeds #{MAX_IDEMPOTENCY_KEY_LENGTH} characters") if
          value.length > MAX_IDEMPOTENCY_KEY_LENGTH
        value
      end

      def request_digest(payload)
        return nil unless @mutation

        value = payload["request_digest"]
        invalid!("a mutation requires a request_digest") unless present_string?(value)
        invalid!("request_digest must be sha256: followed by 64 lowercase hex characters") unless
          REQUEST_DIGEST.match?(value)
        value
      end

      # "Null/absent means create" [contracts: request_fields.expected_revision].
      def expected_revision(payload)
        return nil unless @mutation

        value = payload["expected_revision"]
        return nil if value.nil?
        invalid!("expected_revision must be an integer revision") unless value.is_a?(Integer)
        invalid!("expected_revision must be at least 1") if value < 1
        value
      end

      def present_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
