# frozen_string_literal: true

require "json"

module Kioku
  module Mcp
    # Renders a core (or host) response as an MCP tool result.
    #
    # The mapping is faithful to the frozen contract in both directions.
    # success, partial and queued are not failures and are not marked isError:
    # `partial` carries a real answer with declared gaps, and `queued` is the
    # only honest reply when commit is unavailable. Every other status, and
    # every transport-level error that carries no status at all, is an MCP tool
    # error.
    module Response
      module_function

      def render(payload)
        ::MCP::Tool::Response.new([text_block(payload)], error: failure?(payload))
      end

      def render_error(error, request_id: nil)
        body = {
          "schema_version" => Kioku::SCHEMA_VERSION,
          "request_id" => request_id,
          "status" => error.status,
          "error" => error.to_error_object
        }.compact
        ::MCP::Tool::Response.new([text_block(body)], error: true)
      end

      def failure?(payload)
        return true unless payload.is_a?(Hash)

        status = payload["status"]
        return Kioku::FAILED_STATUSES.include?(status) unless status.nil?

        # No status field means a transport-level rejection, which is frozen
        # behaviour for kioku.invalid_request and kioku.unsupported_schema_version.
        !payload["error"].nil?
      end

      def text_block(payload)
        { type: "text", text: JSON.pretty_generate(payload) }
      end
    end
  end
end
