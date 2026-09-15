# frozen_string_literal: true

module Context
  module Contracts
    # The declared applicability of a global engineering record.
    #
    # Global storage changes visibility, not authority or evidence support
    # (Plan invariant 12). A global record without applicability conditions is
    # refused, because "shared across this installation's projects" is not the
    # same as "true for every project".
    class ApplicabilityConditions < Data.define(
      :languages, :frameworks, :version_constraints, :platforms, :conditions
    )
      LIST_FIELDS = %w[languages frameworks version_constraints platforms].freeze

      def initialize(conditions:, languages: [], frameworks: [], version_constraints: [], platforms: [])
        super
      end

      def self.parse(payload, field: "applicability")
        body = Validator.hash!(Validator.deep_stringify(payload), field: field)
        Validator.reject_unknown!(body, allowed: LIST_FIELDS + ["conditions"], field: field)
        lists = LIST_FIELDS.to_h { |name| [name.to_sym, parse_list(body[name], "#{field}.#{name}")] }
        new(
          conditions: Validator.string!(Validator.required(body, "conditions", field: "#{field}.conditions"),
                                        field: "#{field}.conditions", max: 4096),
          **lists
        )
      end

      def self.parse_list(value, field)
        return [].freeze if value.nil?

        Validator.string_array!(value, field: field, max: 32).map(&:downcase).freeze
      end
      private_class_method :parse_list

      # A global record applies to a project when every dimension it declares
      # is satisfied by the project's stack profile. An undeclared dimension
      # imposes no constraint; a declared one that the profile cannot confirm
      # is a mismatch rather than an assumed match.
      def matches?(stack_profile)
        LIST_FIELDS.all? do |name|
          declared = public_send(name)
          declared.empty? || declared.intersect?(Array(stack_profile[name] || stack_profile[name.to_sym]).map { |v| v.to_s.downcase })
        end
      end

      def to_wire
        to_h.transform_keys(&:to_s)
      end
    end
  end
end
