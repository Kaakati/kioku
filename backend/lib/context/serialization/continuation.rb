# frozen_string_literal: true

require "base64"
require "json"
require "time"

module Context
  module Serialization
    # A bounded continuation handle for reads.
    #
    # The cursor carries a keyset position and the digests of the scope, query,
    # filters, mode and generation vector it was issued against. It is not a
    # credential: the caller's scope is re-authorized on every use, so a cursor
    # can never reach further than the request that presents it. When the
    # binding no longer matches, the caller restarts the query — the contract
    # promises no permanent score ordering (Plan §5.4).
    class Continuation < Data.define(:cursor, :expires_at, :bound, :reset_required_reason)
      DEFAULT_TTL_SECONDS = 300
      MAX_CURSOR_BYTES = 2048
      BOUND_FIELDS = %w[scope_digest query_digest filter_digest mode ranking_config_version generation_vector_digest].freeze

      def self.issue(position:, bound:, now: Time.now.utc, ttl_seconds: DEFAULT_TTL_SECONDS)
        expires_at = now.utc + ttl_seconds
        payload = { "position" => position, "bound" => bound.transform_keys(&:to_s), "expires_at" => expires_at.to_i }
        cursor = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
        raise Errors::QuotaExhausted.new(details: { quota_kind: "cursor_bytes", limit: MAX_CURSOR_BYTES }) if cursor.bytesize > MAX_CURSOR_BYTES

        new(cursor: cursor, expires_at: expires_at, bound: payload["bound"], reset_required_reason: nil)
      end

      # Returns the keyset position, or raises kioku.continuation_expired with
      # the concrete reset reason.
      def self.decode(cursor, bound:, now: Time.now.utc)
        payload = parse(cursor)
        expire!("expired") if payload.fetch("expires_at", 0) <= now.to_i
        expire!(mismatch_reason(payload["bound"], bound.transform_keys(&:to_s)))
        payload.fetch("position")
      end

      def self.parse(cursor)
        Contracts::Validator.string!(cursor, field: "cursor", max: MAX_CURSOR_BYTES)
        payload = JSON.parse(Base64.urlsafe_decode64(cursor))
        raise Errors::ContinuationExpired.new(details: { reset_required_reason: "expired" }) unless payload.is_a?(Hash)

        payload
      rescue ArgumentError, JSON::ParserError
        raise Errors::ContinuationExpired.new(details: { reset_required_reason: "expired" })
      end

      def self.mismatch_reason(presented, expected)
        return nil if presented == expected
        return "index_changed" if presented.is_a?(Hash) && presented["generation_vector_digest"] != expected["generation_vector_digest"]

        "scope_changed"
      end

      def self.expire!(reason)
        return if reason.nil?

        raise Errors::ContinuationExpired.new(details: { reset_required_reason: reason })
      end

      private_class_method :parse, :mismatch_reason, :expire!

      def to_wire
        {
          "cursor" => cursor,
          "expires_at" => expires_at.utc.iso8601(3),
          "bound" => bound,
          "reauthorized_on_use" => true,
          "reset_required_reason" => reset_required_reason
        }
      end
    end
  end
end
