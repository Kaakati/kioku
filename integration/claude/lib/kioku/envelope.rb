# frozen_string_literal: true

module Kioku
  # Builds and validates the common envelope of contracts.json.
  #
  # The host adapter owns schema_version, request_id, deadline_ms and
  # request_digest. The caller owns scope, expected_revision and, optionally,
  # idempotency_key. Actor identity and authority are derived by the core from
  # the authenticated transport: a caller that supplies one is rejected with
  # kioku.invalid_request rather than having it silently dropped.
  module Envelope
    MIN_DEADLINE_MS = 1
    MAX_DEADLINE_MS = 30_000
    STORES = %w[project global both].freeze
    GLOBAL_CATEGORIES = %w[coding_style engineering_decision architecture preferred_library].freeze
    SOURCE_VIEWS = %w[current_worktree commit history].freeze
    RESERVED_FIELDS = %w[authority actor_principal_id origin_role identity agent_authority].freeze

    # The contract excludes request_id, deadline_ms and correlation from the
    # digest. request_digest cannot contain itself, and idempotency_key is
    # excluded here because the adapter derives a default key from the digest --
    # including it would be circular. scope stays in, so the same payload
    # against a different project is a different request.
    DIGEST_EXCLUDED = %w[request_id deadline_ms correlation request_digest idempotency_key].freeze

    module_function

    # Returns [envelope, arguments] with the envelope completed, validated and
    # (for mutations) sealed with a request digest and idempotency key.
    def prepare(arguments, mutation:, default_deadline_ms:)
      args = Kioku::CanonicalJson.canonicalize(arguments || {})
      raise Kioku.invalid_request("tool arguments must be an object") unless args.is_a?(Hash)

      raw = args.delete("envelope") || {}
      raise Kioku.invalid_request("envelope must be an object") unless raw.is_a?(Hash)

      env = apply_defaults(raw, default_deadline_ms)
      validate!(env, mutation: mutation)
      seal_mutation!(env, args) if mutation
      [env, args]
    end

    def apply_defaults(raw, default_deadline_ms)
      env = raw.dup
      env["schema_version"] ||= Kioku::SCHEMA_VERSION
      env["request_id"] ||= Kioku::Ids.uuid7
      env["deadline_ms"] ||= default_deadline_ms
      env
    end

    def validate!(env, mutation:)
      reject_reserved!(env)
      check_schema_version!(env["schema_version"])
      check_request_id!(env["request_id"])
      check_deadline!(env["deadline_ms"])
      check_scope!(env["scope"])
      check_expected_revision!(env["expected_revision"])
      check_idempotency_key!(env["idempotency_key"]) if mutation
      env
    end

    def reject_reserved!(env)
      found = RESERVED_FIELDS & env.keys
      return if found.empty?

      raise Kioku.invalid_request(
        "actor identity and authority are derived by the core and cannot be supplied",
        { "rejected_fields" => found }
      )
    end

    def check_schema_version!(value)
      return if value == Kioku::SCHEMA_VERSION

      raise Kioku::Error.new(
        "kioku.unsupported_schema_version",
        "unsupported schema_version",
        details: { "supported" => [Kioku::SCHEMA_VERSION], "requested" => value }
      )
    end

    def check_request_id!(value)
      return if Kioku::Ids.uuid?(value)

      raise Kioku.invalid_request("request_id must be a 36-character lowercase UUID")
    end

    def check_deadline!(value)
      return if value.is_a?(Integer) && value.between?(MIN_DEADLINE_MS, MAX_DEADLINE_MS)

      raise Kioku.invalid_request(
        "deadline_ms must be an integer between #{MIN_DEADLINE_MS} and #{MAX_DEADLINE_MS}"
      )
    end

    def check_scope!(scope)
      raise Kioku.invalid_request("scope is required") unless scope.is_a?(Hash)

      store = scope["store"]
      raise Kioku.invalid_request("scope.store must be one of #{STORES.join('|')}") unless STORES.include?(store)

      check_project_key!(scope, store)
      check_categories!(scope["global_categories"])
      check_source_view!(scope["source_view"])
    end

    # A global operation declares store=global explicitly; it is never reached
    # by omitting project_key, and a missing binding never falls back to global.
    def check_project_key!(scope, store)
      return unless %w[project both].include?(store)

      key = scope["project_key"]
      return if key.is_a?(String) && !key.strip.empty?

      raise Kioku::Error.new(
        "kioku.project_binding_unresolved",
        "scope.project_key is required when scope.store is #{store}",
        details: { "setup_required" => true }
      )
    end

    def check_categories!(values)
      return if values.nil?
      raise Kioku.invalid_request("scope.global_categories must be an array") unless values.is_a?(Array)

      rejected = values - GLOBAL_CATEGORIES
      return if rejected.empty?

      raise Kioku.invalid_request("unknown scope.global_categories", { "rejected" => rejected })
    end

    def check_source_view!(value)
      return if value.nil? || SOURCE_VIEWS.include?(value)

      raise Kioku.invalid_request("unknown scope.source_view", { "rejected" => value })
    end

    def check_expected_revision!(value)
      return if value.nil?
      return if value.is_a?(Integer) && value >= 1

      raise Kioku.invalid_request("expected_revision must be a positive integer or null")
    end

    def check_idempotency_key!(value)
      return if value.nil?
      return if value.is_a?(String) && !value.empty? && value.bytesize <= 128

      raise Kioku.invalid_request("idempotency_key must be 1..128 bytes")
    end

    # Computes the request digest and, when the caller supplied no key, derives
    # a deterministic idempotency key from it. A replayed identical payload then
    # returns the prior receipt instead of writing a second memory; a caller
    # that genuinely wants two identical records supplies distinct keys.
    def seal_mutation!(env, args)
      digest = request_digest(env, args)
      supplied = env["request_digest"]
      if supplied && supplied != digest
        raise Kioku.invalid_request("request_digest is computed by the host adapter and must not be supplied")
      end

      env["request_digest"] = digest
      env["idempotency_key"] ||= digest.delete_prefix("sha256:")
      env
    end

    def request_digest(env, args)
      body = {
        "envelope" => env.reject { |key, _| DIGEST_EXCLUDED.include?(key) },
        "arguments" => args
      }
      Kioku::CanonicalJson.digest(body)
    end
  end
end
