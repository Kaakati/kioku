# frozen_string_literal: true

require "digest"
require "json"

require_relative "contracts"

module Kioku
  # "SHA-256 over the canonicalized request body excluding request_id, deadline_ms and
  # correlation. Digest input includes project_key, so the same payload in a different
  # project is a different request" [contracts: request_fields.request_digest; plan §5.2].
  #
  # Canonicalization sorts object keys at every depth and leaves arrays in order, so key
  # insertion order cannot change a digest while a removed evidence link can. Values are
  # serialized by JSON type, so the integer 4 and the string "4" are different requests.
  #
  # E1: "The core RECOMPUTES the digest over the received body and compares it to the
  # asserted value. A caller-asserted digest never decides a durability claim"
  # [contracts: contract.json request_digest.authority]. `Kioku::Mcp::ToolContract` is
  # the caller at the host boundary, which is the earliest point at which the whole body
  # is in hand.
  module RequestDigest
    # The declared exclusions, plus request_digest itself. A digest cannot be one of its
    # own inputs: if the asserted value were digested, no recomputation could ever be
    # compared against it, and the comparison is the whole point.
    EXCLUDED_FIELDS = (Contracts.digest_rule.fetch("excluded_fields") + %w[request_digest]).freeze

    module_function

    def compute(payload)
      canonical = JSON.generate(canonicalize(without_excluded_fields(payload)))

      "sha256:#{Digest::SHA256.hexdigest(canonical)}"
    end

    # "excluded_at: [$, $.envelope]" — the two levels the excluded names may appear at.
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
