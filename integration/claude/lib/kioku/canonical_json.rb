# frozen_string_literal: true

require "json"
require "digest"

module Kioku
  # Deterministic JSON used for request digests. Keys are stringified and
  # sorted at every depth so that two structurally identical payloads always
  # produce the same digest regardless of construction order.
  module CanonicalJson
    module_function

    def dump(value)
      JSON.generate(canonicalize(value))
    end

    def digest(value)
      "sha256:#{Digest::SHA256.hexdigest(dump(value))}"
    end

    def canonicalize(value)
      case value
      when Hash then canonicalize_hash(value)
      when Array then value.map { |item| canonicalize(item) }
      when Symbol then value.to_s
      else value
      end
    end

    def canonicalize_hash(hash)
      pairs = hash.map { |key, value| [key.to_s, value] }
      pairs.sort_by!(&:first)
      pairs.each_with_object({}) { |(key, value), out| out[key] = canonicalize(value) }
    end
  end
end
