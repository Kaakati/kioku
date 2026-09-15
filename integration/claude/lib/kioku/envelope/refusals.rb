# frozen_string_literal: true

require_relative "../errors"

module Kioku
  module Envelope
    # Refusal helpers shared by both envelope parsers. Messages name fields only: an
    # error message is operator-facing and content-redacted [contracts:
    # response_fields.error; plan §9].
    module Refusals
      def invalid!(detail, details = {})
        raise Kioku::Error.new("kioku.invalid_request", message: detail, details: details)
      end

      def unsupported_version!(version)
        raise Kioku::Error.new("kioku.unsupported_schema_version",
                               message: "schema version #{version} is not supported by this contract",
                               details: { "declared" => version })
      end
    end
  end
end
