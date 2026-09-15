# frozen_string_literal: true

require "json"
require "time"

require_relative "../errors"

module Kioku
  module Mcp
    # Renders a Kioku response envelope as one MCP tool result.
    #
    # A refusal is rendered as the envelope itself rather than as prose, so a caller reads
    # one field to branch: status, error.code, error.retryable. A refusal carries no data,
    # so an empty candidate set can never be mistaken for an answer, and kioku.invalid_request
    # carries no status because v1 has no tenth status value
    # [contracts: errors kioku.invalid_request; open_decisions].
    module Renderer
      SCHEMA_VERSION = "kioku.tool.v1"

      module_function

      def success(envelope)
        content(envelope, error: false)
      end

      def refusal(error, request_id: nil)
        content(refusal_envelope(error, request_id), error: true)
      end

      def refusal_envelope(error, request_id)
        body = {
          "schema_version" => SCHEMA_VERSION,
          "request_id" => request_id,
          "error" => error_body(error),
          "data" => nil,
          "warnings" => [],
          "server_time" => Time.now.utc.iso8601
        }
        error.status.nil? ? body : body.merge("status" => error.status)
      end

      def error_body(error)
        { "code" => error.code, "message" => error.message, "retryable" => error.retryable?,
          "retry_after_ms" => nil, "details" => error.details }
      end

      def content(envelope, error:)
        ::MCP::Tool::Response.new([{ type: "text", text: JSON.generate(envelope) }], error: error)
      end
    end
  end
end
