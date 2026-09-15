# frozen_string_literal: true

require "mcp"

require_relative "contract_schema"
require_relative "dispatch"
require_relative "schemas"
require_relative "stdio_transport"
require_relative "../version"

module Kioku
  module Mcp
    # The six-tool MCP stdio adapter built on the official Ruby MCP SDK [plan §4.2].
    #
    # "context-mcp | Six versioned MCP tools, cancellation, request/receipt correlation |
    # stdout is reserved for MCP; no storage authority" [plan §3].
    class Server
      SERVER_NAME = "kioku"

      def initialize(link:, logger:)
        @dispatch = Dispatch.new(link: link, logger: logger)
        @logger = logger
      end

      def run
        configure
        StdioTransport.new(build, logger: @logger).open
      end

      def build
        ::MCP::Server.new(name: SERVER_NAME, version: Kioku::VERSION, tools: tools)
      end

      private

      def configure
        logger = @logger
        ::MCP.configure do |configuration|
          # Refusals are the contract validator's to name; see ContractSchema.
          configuration.validate_tool_call_arguments = false
          configuration.exception_reporter = ->(error, _context) { logger.error("adapter error: #{error.class}") }
        end
      end

      def tools
        dispatch = @dispatch
        Schemas.all.map do |name, schema|
          ::MCP::Tool.define(name: name,
                             description: Schemas.description(name),
                             input_schema: ContractSchema.new(schema)) do |server_context: nil, **arguments|
            dispatch.call(tool: name, arguments: arguments)
          end
        end
      end
    end
  end
end
