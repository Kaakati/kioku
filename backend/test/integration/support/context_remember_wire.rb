# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Kioku
  module Test
    # Wire-level arrangement for the one end-to-end path B2 lands:
    # POST /api/v1/context_remember, the common mutation envelope, and a
    # request_digest computed the way the shared contract defines it.
    #
    # The digest is computed HERE rather than read from a core constant on
    # purpose. contracts/v1/contract.json says the core "RECOMPUTES the digest
    # over the received body and compares it to the asserted value", so a test
    # that asked the core for the digest it expects would agree with the core by
    # construction and could never catch a divergence. This is an independent
    # transcription of the published rule:
    #
    #   * object keys sorted lexicographically at every depth, arrays in order;
    #   * values serialized by JSON type, so 4 and "4" digest differently;
    #   * request_id, deadline_ms and correlation removed at $ and at $.envelope;
    #   * request_digest itself removed — a caller computes the digest over the
    #     call it is about to make and then attaches it, so the field cannot be
    #     part of its own input.
    module ContextRememberWire
      REMEMBER_PATH = "/api/v1/context_remember"
      BRIDGE_TOKEN = "test-bridge-token"
      LOOPBACK_HOST = "127.0.0.1:7310"

      # "request_id, deadline_ms and correlation" plus the self-referential digest.
      DIGEST_EXCLUDED = %w[request_id deadline_ms correlation request_digest].freeze

      # "string (UUIDv7, 36 chars)" [contracts.json request_fields.request_id].
      def wire_request_id
        SecureRandom.uuid_v7
      end

      def remember_envelope(idempotency_key:, project_key:, deadline_ms: 5000,
                            expected_revision: nil, schema_version: "kioku.tool.v1")
        {
          "schema_version" => schema_version,
          "request_id" => wire_request_id,
          "deadline_ms" => deadline_ms,
          "scope" => { "store" => "project", "project_key" => project_key },
          "idempotency_key" => idempotency_key,
          "expected_revision" => expected_revision
        }
      end

      # The complete context_remember call, with its request_digest computed over
      # itself. Only the seven inputs contracts.json marks required or optional
      # for this phase are sent.
      def remember_body(project_key:, object_key:, idempotency_key: "idem-#{SecureRandom.hex(6)}",
                        kind: "decision", title: "Invoice retry fails under concurrent workers",
                        body: "Two workers claimed the same invoice lease; the retry double-charged.",
                        relation: "supports", memory_key: nil, expected_revision: nil,
                        envelope_overrides: {}, digest_of: nil)
        payload = {
          "envelope" => remember_envelope(idempotency_key: idempotency_key,
                                          project_key: project_key,
                                          expected_revision: expected_revision)
                        .merge(envelope_overrides),
          "kind" => kind,
          "destination" => { "store_kind" => "project", "project_key" => project_key },
          "title" => title,
          "body" => body,
          "evidence" => [{ "ref" => { "object_key" => object_key }, "relation" => relation }]
        }
        payload["memory_key"] = memory_key if memory_key
        sign(payload, digest_of)
      end

      def sign(payload, override)
        payload["envelope"] = payload["envelope"].merge(
          "request_digest" => override || contract_request_digest(payload)
        )
        payload
      end

      def contract_request_digest(payload)
        body = strip_excluded(payload)
        body["envelope"] = strip_excluded(body["envelope"]) if body["envelope"].is_a?(Hash)

        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(body)))}"
      end

      def strip_excluded(hash)
        hash.reject { |key, _| DIGEST_EXCLUDED.include?(key.to_s) }
      end

      def canonicalize(value)
        case value
        when Hash
          value.to_a.sort_by { |key, _| key.to_s }
               .each_with_object({}) { |(key, item), out| out[key.to_s] = canonicalize(item) }
        when Array then value.map { |item| canonicalize(item) }
        else value
        end
      end

      def bridge_headers(token: BRIDGE_TOKEN, host: LOOPBACK_HOST)
        headers = { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => host }
        headers["HTTP_AUTHORIZATION"] = "Bearer #{token}" unless token.nil?
        headers
      end

      # Issues the call and returns the parsed response envelope.
      def post_remember(payload, token: BRIDGE_TOKEN, host: LOOPBACK_HOST, path: REMEMBER_PATH)
        post path, params: JSON.generate(payload), headers: bridge_headers(token: token, host: host)
        parsed_envelope
      end

      def parsed_envelope
        JSON.parse(response.body)
      rescue JSON::ParserError
        flunk("the response body was not JSON (HTTP #{response.status}): #{response.body[0, 400]}")
      end

      # The installation the bridge credential is paired to, and the origin role
      # that pairing carries (plan 6.3 "Pair bridge credentials to an
      # installation and approved roots"). Declared as configuration so the two
      # values come from the authenticated transport's own binding rather than
      # from request text.
      INSTALLATION_ENV = "KIOKU_BRIDGE_INSTALLATION_KEY"
      ORIGIN_ROLE_ENV = "KIOKU_BRIDGE_ORIGIN_ROLE"

      def with_bridge_pairing(installation_key:, origin_role: "user")
        previous = ENV.values_at(INSTALLATION_ENV, ORIGIN_ROLE_ENV)
        ENV[INSTALLATION_ENV] = installation_key
        ENV[ORIGIN_ROLE_ENV] = origin_role
        yield
      ensure
        ENV[INSTALLATION_ENV] = previous[0]
        ENV[ORIGIN_ROLE_ENV] = previous[1]
      end
    end
  end
end
