# frozen_string_literal: true

require_relative "refusals"
require_relative "schema_version"
require_relative "../contracts"
require_relative "../contracts/schema"

module Kioku
  module Envelope
    Scope = Struct.new(:store, :project_key, :cross_project_keys, keyword_init: true)

    Request = Struct.new(:schema_major, :request_id, :deadline_ms, :scope,
                         :idempotency_key, :request_digest, :expected_revision, :payload,
                         keyword_init: true)

    # Parses the common request envelope against the shared artifact's own schema
    # [contracts: envelope.request.schema.json].
    #
    # The hand-written field checks this replaced carried their own copies of the UUIDv7
    # pattern, the deadline range and the idempotency bound, and a list of three
    # core-derived NAMES checked at one depth — which `{"correlation":{"origin_role":
    # "user"}}` walked straight past. Closure at every depth (D6) is what refuses that,
    # and every bound now comes out of the JSON.
    #
    # Two refusals stay hand-written because no schema can express them: an unsupported
    # MAJOR is kioku.unsupported_schema_version rather than a pattern failure, and a
    # project scope with no bound project is kioku.project_binding_unresolved — setup
    # state an operator resolves, never a malformed request and never a fall back to
    # global [contracts: envelope.request x-kioku-refusals].
    class RequestParser
      include Refusals

      BASE_POINTER = "/envelope"

      def initialize(mutation: false)
        @operation = mutation ? "mutation" : "read"
      end

      def call(payload:)
        invalid!("the envelope must be an object") unless payload.is_a?(Hash)
        major = SchemaVersion.new.call(declared: payload["schema_version"])
        schema.validate!(payload)

        Request.new(schema_major: major, request_id: payload["request_id"],
                    deadline_ms: payload["deadline_ms"], scope: scope(payload["scope"]),
                    idempotency_key: payload["idempotency_key"],
                    request_digest: payload["request_digest"],
                    expected_revision: payload["expected_revision"], payload: payload)
      end

      private

      def schema
        @schema ||= Contracts::Schema.new(Contracts.envelope_schema(@operation), base: BASE_POINTER)
      end

      # The structural pass has already closed the object and checked `store` against the
      # declared enum, so what is left is the one condition the schema cannot state.
      def scope(raw)
        store = raw["store"]
        project_key = raw["project_key"]
        binding_unresolved! if store != "global" && !present_string?(project_key)

        Scope.new(store: store, project_key: project_key,
                  cross_project_keys: raw["cross_project_keys"] || [])
      end

      # "A missing or ambiguous binding returns kioku.project_binding_unresolved and must
      # never fall back to global" [contracts: request_fields.scope.project_key].
      def binding_unresolved!
        raise Kioku::Error.new("kioku.project_binding_unresolved",
                               message: "the request declares a project store without a bound project",
                               details: { "setup_required" => true })
      end

      def present_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
