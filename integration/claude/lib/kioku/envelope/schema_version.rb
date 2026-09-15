# frozen_string_literal: true

require_relative "refusals"
require_relative "../contracts"

module Kioku
  module Envelope
    # D2. "Rejected with kioku.unsupported_schema_version if the major does not match a
    # supported contract. Minor additions are additive-only"
    # [contracts: request_fields.schema_version].
    #
    # The accepted set is the artifact's own pattern, so relaxing or tightening it in
    # Ruby cannot change what this package takes. Accepting an unknown minor does not
    # widen the accepted surface: every request object is closed, so a field a later
    # minor adds is still refused by name and the caller learns the version was fine and
    # this one field is not taken yet.
    class SchemaVersion
      include Refusals

      # The contract freezes the SUPPORTED pattern only. This one exists for a single
      # purpose: telling a declared contract version this core does not implement —
      # another major, or another contract family altogether — which is
      # kioku.unsupported_schema_version, from a string that is not a version at all,
      # which is kioku.invalid_request [contracts: envelope.request x-kioku-refusals
      # schema_version_major_mismatch / schema_version_absent_or_malformed].
      VERSIONED_CONTRACT = /\A[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*\.v\d+(?:\.(?:0|[1-9][0-9]*))?\z/

      def call(declared:)
        invalid!("schema_version is required") unless declared.is_a?(String)
        return Contracts.supported_major if Contracts.schema_version_pattern.match?(declared)

        invalid!("schema_version does not name a contract version") unless
          VERSIONED_CONTRACT.match?(declared)
        unsupported_version!(declared)
      end
    end
  end
end
