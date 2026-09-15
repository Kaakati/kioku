# frozen_string_literal: true

require_relative "refusals"

module Kioku
  module Envelope
    # "Rejected with kioku.unsupported_schema_version if the major does not match a
    # supported contract. Minor additions are additive-only"
    # [contracts: request_fields.schema_version].
    class SchemaVersion
      include Refusals

      PATTERN = /\Akioku\.tool\.v(\d+)(?:\.(\d+))?\z/
      SUPPORTED_MAJOR = 1

      def call(declared:)
        invalid!("schema_version is required") unless declared.is_a?(String)

        match = PATTERN.match(declared)
        unsupported_version!(declared) if match.nil?

        major = match[1].to_i
        unsupported_version!(declared) unless major == SUPPORTED_MAJOR
        major
      end
    end
  end
end
