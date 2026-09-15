# frozen_string_literal: true

module Context
  module Contracts
    # The project-exception variant of a memory write.
    #
    # It writes a project-owned override row pointing at an exact global
    # revision and leaves that global revision unchanged: one project's
    # exception never edits the shared record (Plan §1.3). Whether the override
    # may take effect at all is authority policy, not contract shape —
    # Context::Domain::Preferences::Resolution decides that.
    class OverrideRequest < Data.define(
      :target_global_memory_key, :target_revision, :replacement_body,
      :exclusion, :reason, :authority_basis, :valid_from, :valid_until
    )
      FIELDS = %w[
        target_global_memory_key target_revision replacement_body
        exclusion reason authority_basis validity_interval
      ].freeze

      def initialize(target_global_memory_key:, target_revision:, reason:, replacement_body: nil,
                     exclusion: false, authority_basis: nil, valid_from: nil, valid_until: nil)
        super
      end

      def self.parse(payload, field: "override")
        body = Validator.hash!(Validator.deep_stringify(payload), field: field)
        Validator.reject_unknown!(body, allowed: FIELDS, field: field)
        interval = parse_interval(body["validity_interval"], field)
        new(**attributes(body, field).merge(interval)).validate!(field)
      end

      def self.attributes(body, field)
        {
          target_global_memory_key: Validator.string!(
            Validator.required(body, "target_global_memory_key", field: "#{field}.target_global_memory_key"),
            field: "#{field}.target_global_memory_key", max: 128
          ),
          target_revision: Validator.integer!(Validator.required(body, "target_revision", field: "#{field}.target_revision"),
                                              field: "#{field}.target_revision", min: 1, max: 2**62),
          reason: Validator.string!(Validator.required(body, "reason", field: "#{field}.reason"), field: "#{field}.reason", max: 4096),
          replacement_body: body["replacement_body"] && Validator.string!(body["replacement_body"], field: "#{field}.replacement_body", max: 16_384),
          exclusion: body.fetch("exclusion", false).then { |value| Validator.boolean!(value, field: "#{field}.exclusion") },
          authority_basis: body["authority_basis"] && Validator.string!(body["authority_basis"], field: "#{field}.authority_basis", max: 1024)
        }
      end

      def self.parse_interval(value, field)
        return { valid_from: nil, valid_until: nil } if value.nil?

        interval = Validator.hash!(value, field: "#{field}.validity_interval")
        Validator.reject_unknown!(interval, allowed: %w[valid_from valid_until], field: "#{field}.validity_interval")
        {
          valid_from: Validator.time!(interval["valid_from"], field: "#{field}.validity_interval.valid_from"),
          valid_until: Validator.time!(interval["valid_until"], field: "#{field}.validity_interval.valid_until")
        }
      end

      private_class_method :attributes, :parse_interval

      def validate!(field = "override")
        Validator.invalid!(field, "replacement_or_exclusion_required") if replacement_body.nil? && !exclusion
        Validator.invalid!(field, "replacement_and_exclusion_conflict") if replacement_body && exclusion
        if valid_from && valid_until && valid_until <= valid_from
          Validator.invalid!("#{field}.validity_interval", "valid_until_not_after_valid_from")
        end
        self
      end

      def target_handle = TypedHandle.new(kind: "global_record_revision", key: target_global_memory_key, revision: target_revision)
    end
  end
end
