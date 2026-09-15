# frozen_string_literal: true

module Context
  module Contracts
    # The split write of Plan §1.3: a local application record plus a reusable
    # global record joined by provenance.
    #
    # The global side carries the reusable statement, its rationale, its
    # applicability conditions and a permitted excerpt only. It never copies
    # project logs, private paths or source wholesale, and a global reference
    # to project evidence grants no other project access to that evidence.
    class Derivative < Data.define(
      :publish_global, :category, :source_revision, :permitted_excerpt,
      :title, :body, :rationale, :tradeoffs, :applicability
    )
      FIELDS = %w[
        publish_global category source_revision permitted_excerpt
        title body rationale tradeoffs applicability
      ].freeze

      def initialize(publish_global:, category:, title:, body:, applicability:,
                     source_revision: nil, permitted_excerpt: nil, rationale: nil, tradeoffs: nil)
        super
      end

      def self.parse(payload, field: "derivative")
        body = Validator.hash!(Validator.deep_stringify(payload), field: field)
        Validator.reject_unknown!(body, allowed: FIELDS, field: field)
        new(**required_attributes(body, field).merge(optional_attributes(body, field)))
      end

      def self.required_attributes(body, field)
        {
          publish_global: Validator.boolean!(Validator.required(body, "publish_global", field: "#{field}.publish_global"),
                                             field: "#{field}.publish_global"),
          category: Validator.enum!(Validator.required(body, "category", field: "#{field}.category"),
                                    field: "#{field}.category", allowed: Vocabulary.global_categories),
          title: Validator.string!(Validator.required(body, "title", field: "#{field}.title"), field: "#{field}.title", max: 200),
          body: Validator.string!(Validator.required(body, "body", field: "#{field}.body"), field: "#{field}.body", max: 16_384),
          applicability: ApplicabilityConditions.parse(
            Validator.required(body, "applicability", field: "#{field}.applicability"), field: "#{field}.applicability"
          )
        }
      end

      def self.optional_attributes(body, field)
        {
          source_revision: body["source_revision"] && Validator.integer!(body["source_revision"], field: "#{field}.source_revision", min: 1, max: 2**62),
          permitted_excerpt: body["permitted_excerpt"] && Validator.string!(body["permitted_excerpt"], field: "#{field}.permitted_excerpt", max: 4096),
          rationale: body["rationale"] && Validator.string!(body["rationale"], field: "#{field}.rationale", max: 8192),
          tradeoffs: body["tradeoffs"] && Validator.string!(body["tradeoffs"], field: "#{field}.tradeoffs", max: 8192)
        }
      end

      private_class_method :required_attributes, :optional_attributes

      def destination(origin_project_key:)
        Destination.new(store_kind: "global", category: category, origin_project_key: origin_project_key)
      end
    end
  end
end
