# frozen_string_literal: true

require "digest"
require "json"

module Context
  module Contracts
    # "SHA-256 over the canonicalized request body excluding request_id, deadline_ms and
    # correlation. Digest input includes project_key, so the same payload in a different
    # project is a different request" [contracts: request_fields.request_digest; plan §5.2].
    #
    # E1. "The core RECOMPUTES the digest over the received body and compares it to the
    # asserted value. A caller-asserted digest never decides a durability claim"
    # [contracts: contract.json request_digest.authority].
    #
    # The core had no implementation at all and checked only that the asserted string was
    # sha256 plus 64 hex characters, so `Remember#replay` compared the caller's ASSERTED
    # digest against the stored one: a caller reusing an idempotency key with a stale
    # digest was told `saved` for content that was never written, and the same content
    # under a different asserted digest was refused as a conflict for a request the core
    # had already committed.
    #
    # Canonicalization sorts object keys at every depth and leaves arrays in order, so key
    # insertion order cannot change a digest while a removed evidence link can. Values are
    # serialized by JSON type, so the integer 4 and the string "4" are different requests.
    # The identical literal is pinned in both suites over the identical artifact body,
    # because two implementations of one rule can each be self-consistent and disagree.
    module RequestDigest
      # The declared exclusions, plus request_digest itself. A digest cannot be one of its
      # own inputs: if the asserted value were digested, no recomputation could ever be
      # compared against it, and the comparison is the whole point.
      EXCLUDED_FIELDS = (Contracts.digest_rule.fetch("excluded_fields") + %w[request_digest]).freeze

      WIRE_FORMAT = Regexp.new(Contracts.digest_rule.fetch("wire_format"))

      module_function

      def compute(payload)
        canonical = JSON.generate(canonicalize(without_excluded_fields(payload)))

        "sha256:#{Digest::SHA256.hexdigest(canonical)}"
      end

      # True when the asserted digest is the digest of the body it arrived with. The
      # comparison is what the authority rule asks for; a shape check alone leaves the
      # caller's assertion deciding.
      def describes?(payload, asserted)
        asserted.is_a?(String) && WIRE_FORMAT.match?(asserted) && compute(payload) == asserted
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
end
