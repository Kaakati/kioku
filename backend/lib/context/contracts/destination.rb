# frozen_string_literal: true

module Context
  module Contracts
    # Where a memory is written. Exactly one destination, always explicit.
    #
    # store_kind=project owns a project_key; store_kind=global owns no project
    # and carries a category. origin_project_key is provenance on a global
    # record, not ownership. A missing project binding raises
    # kioku.project_binding_unresolved: it is never read as permission to
    # write globally (Plan §5.2, invariant 11).
    class Destination < Data.define(:store_kind, :project_key, :category, :origin_project_key)
      def initialize(store_kind:, project_key: nil, category: nil, origin_project_key: nil) = super

      def self.parse(payload, field: "destination", origin_project_key: nil)
        body = Validator.hash!(Validator.deep_stringify(payload), field: field)
        Validator.reject_unknown!(body, allowed: %w[store_kind project_key category], field: field)
        store_kind = Validator.enum!(Validator.required(body, "store_kind", field: "#{field}.store_kind"),
                                     field: "#{field}.store_kind", allowed: Vocabulary.store_kinds)
        new(
          store_kind: store_kind,
          project_key: parse_project_key(body["project_key"], store_kind, field),
          category: parse_category(body["category"], store_kind, field),
          origin_project_key: origin_project_key
        ).validate!
      end

      def self.parse_project_key(value, store_kind, field)
        if store_kind == "project"
          raise Errors::ProjectBindingUnresolved.new(details: { field: "#{field}.project_key", setup_required: true }) if value.nil?

          return Validator.string!(value, field: "#{field}.project_key", max: 128)
        end
        Validator.invalid!("#{field}.project_key", "not_allowed_for_global_destination") unless value.nil?
        nil
      end

      def self.parse_category(value, store_kind, field)
        if store_kind == "global"
          Validator.invalid!("#{field}.category", "missing") if value.nil?
          return Validator.enum!(value, field: "#{field}.category", allowed: Vocabulary.global_categories)
        end
        Validator.invalid!("#{field}.category", "not_allowed_for_project_destination") unless value.nil?
        nil
      end

      private_class_method :parse_project_key, :parse_category

      def validate!
        Validator.invalid!("destination.project_key", "missing") if project? && project_key.nil?
        Validator.invalid!("destination.category", "missing") if global? && category.nil?
        self
      end

      def project? = store_kind == "project"
      def global? = store_kind == "global"

      def owner
        { project_key: project_key, origin_project_key: origin_project_key }
      end
    end
  end
end
