# frozen_string_literal: true

require "digest"
require "json"

module Kioku
  # "SHA-256 over the canonicalized request body excluding request_id, deadline_ms and
  # correlation. Digest input includes project_key, so the same payload in a different
  # project is a different request" [contracts: request_fields.request_digest; plan §5.2].
  #
  # Canonicalization sorts object keys at every depth and leaves arrays in order, so key
  # insertion order cannot change a digest while a removed evidence link can. Values are
  # serialized by JSON type, so the integer 4 and the string "4" are different requests.
  module RequestDigest
    EXCLUDED_FIELDS = %w[request_id deadline_ms correlation].freeze

    module_function

    def compute(payload)
      canonical = JSON.generate(canonicalize(without_excluded_fields(payload)))

      "sha256:#{Digest::SHA256.hexdigest(canonical)}"
    end

    def without_excluded_fields(payload)
      body = reject_excluded(payload)
      envelope = body["envelope"]
      body["envelope"] = reject_excluded(envelope) if envelope.is_a?(Hash)
      body
    end

    def reject_excluded(hash)
      hash.reject { |key, _| EXCLUDED_FIELDS.include?(key.to_s) }
    end

    def canonicalize(value)
      case value
      when Hash
        value.to_a.sort_by { |key, _| key.to_s }
             .each_with_object({}) { |(key, item), out| out[key.to_s] = canonicalize(item) }
      when Array
        value.map { |item| canonicalize(item) }
      else
        value
      end
    end
  end
end
