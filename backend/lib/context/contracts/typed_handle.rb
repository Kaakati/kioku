# frozen_string_literal: true

module Context
  module Contracts
    # A typed reference to something the core owns.
    #
    # A handle grants no access by itself: every boundary re-authorizes scope
    # and re-checks deletion state before resolving one (Plan invariant 5).
    class TypedHandle < Data.define(:kind, :key, :revision)
      def initialize(kind:, key:, revision: nil) = super

      def self.parse(payload, field:)
        body = Validator.hash!(Validator.deep_stringify(payload), field: field)
        Validator.reject_unknown!(body, allowed: %w[kind key revision], field: field)
        new(
          kind: Validator.enum!(Validator.required(body, "kind", field: "#{field}.kind"),
                                field: "#{field}.kind", allowed: Vocabulary.handle_kinds),
          key: Validator.string!(Validator.required(body, "key", field: "#{field}.key"), field: "#{field}.key", max: 512),
          revision: parse_revision(body["revision"], field)
        )
      end

      def self.parse_revision(value, field)
        value.nil? ? nil : Validator.integer!(value, field: "#{field}.revision", min: 1, max: 2**62)
      end
      private_class_method :parse_revision

      def to_s = revision ? "#{kind}:#{key}@#{revision}" : "#{kind}:#{key}"
    end
  end
end
