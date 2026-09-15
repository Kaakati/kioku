# frozen_string_literal: true

require_relative "errors"
require_relative "envelope/refusals"
require_relative "envelope/schema_version"
require_relative "envelope/request_parser"
require_relative "envelope/response_parser"

module Kioku
  # The common kioku.tool.v1 envelope [contracts: envelope.request_fields /
  # envelope.response_fields; plan §6.1].
  #
  # The host parses both directions. It refuses a malformed request before any host
  # round-trip, and it refuses a malformed or dishonest response before rendering it,
  # so a queued write is never handed to the model as a save.
  module Envelope
    module_function

    def parse_request(payload, mutation: false)
      RequestParser.new(mutation: mutation).call(payload: payload)
    end

    def parse_response(payload, expected_request_id: nil)
      ResponseParser.new.call(payload: payload, expected_request_id: expected_request_id)
    end
  end
end
