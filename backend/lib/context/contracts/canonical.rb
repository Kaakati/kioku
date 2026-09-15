# frozen_string_literal: true

require "digest"
require "json"
require "time"

module Context
  module Contracts
    # Canonical encoding and SHA-256 digests.
    #
    # One encoding is used everywhere a digest has to be reproducible by a
    # different process: request digests, scope and filter digests bound into a
    # continuation cursor, and the rendered hash in token accounting. Object
    # content addressing uses the same algorithm (Plan §4.2) and the algorithm
    # name travels with every handle, so it can be versioned later.
    module Canonical
      ALGORITHM = "sha256"

      module_function

      # Deterministic JSON: object keys sorted, no insertion-order dependence.
      def encode(value)
        JSON.generate(normalize(value))
      end

      def normalize(value)
        case value
        when Hash then value.map { |key, nested| [key.to_s, normalize(nested)] }.sort_by(&:first).to_h
        when Array then value.map { |item| normalize(item) }
        when Symbol then value.to_s
        when Time then value.utc.iso8601(3)
        else value
        end
      end

      def digest(value)
        hex(encode(value))
      end

      def hex(bytes)
        "#{ALGORITHM}:#{::Digest::SHA256.hexdigest(bytes)}"
      end

      # The request digest excludes request_id, deadline_ms and correlation, so
      # a retry with a fresh request_id and a new budget still replays onto the
      # same idempotency receipt. project_key is inside the digest input, so the
      # same payload in a different project is a different request (Plan §5.2).
      EXCLUDED_FROM_REQUEST_DIGEST = %w[request_id deadline_ms correlation].freeze

      def request_digest(payload)
        body = Validator.deep_stringify(payload)
        envelope = body["envelope"]
        body = body.merge("envelope" => envelope.except(*EXCLUDED_FROM_REQUEST_DIGEST)) if envelope.is_a?(Hash)
        digest(body)
      end
    end
  end
end
