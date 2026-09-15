# frozen_string_literal: true

require "mcp"
require_relative "../schemas"
require_relative "../tool_request"
require_relative "response"
require_relative "client"
require_relative "validation"

module Kioku
  module Mcp
    # The MCP stdio server.
    #
    # STDOUT belongs to the MCP protocol. Every diagnostic this process emits
    # goes to stderr, including the SDK's own exception reporting, because a
    # single stray line on stdout desynchronises the client.
    #
    # The server holds no storage authority: each tool forwards to
    # context-agent over the private Unix socket and renders what comes back.
    class Runner
      INSTRUCTIONS = <<~TEXT
        Kioku stores project-owned memory (tasks, decisions, attempts, evidence) and applicable
        global engineering records. Retrieval is exact lookup, lexical BM25 match or bounded typed
        traversal; there is no semantic or hybrid mode. A returned record is authentic, not
        necessarily true: authority, lifecycle, availability, applicability, claim support and
        coverage are reported separately and must not be collapsed into one verified flag.
        context_remember answers saved only after canonical commit, and queued after durable host
        enqueue.
      TEXT

      def initialize(config: Kioku::Config.load, logger: Kioku::Logger.new(component: "context-mcp"))
        @config = config
        @logger = logger
        @client = Client.new(config: config, logger: logger)
        @validator = Validator.new
      end

      def run
        configure_sdk
        ::MCP::Server::Transports::StdioTransport.new(build_server).open
        0
      rescue Interrupt
        0
      rescue StandardError => e
        @logger.error("mcp server stopped", error: e.class.name, detail: e.message)
        1
      ensure
        @client.close
      end

      def build_server
        ::MCP::Server.new(
          name: "kioku",
          title: "Kioku project and global memory",
          version: Kioku::VERSION,
          instructions: INSTRUCTIONS,
          tools: Kioku::TOOLS.map { |tool| build_tool(tool) }
        )
      end

      # Entry point for every generated tool. Errors are mapped to their frozen
      # wire names rather than leaking a Ruby exception to the model.
      def invoke(tool, arguments)
        Response.render(@client.call(decode(tool, arguments)))
      rescue Kioku::Error => e
        @logger.warn("tool call rejected", tool: tool, code: e.code)
        Response.render_error(e)
      rescue StandardError => e
        @logger.error("tool call failed", tool: tool, error: e.class.name, detail: e.message)
        Response.render_error(
          Kioku::Error.new("kioku.internal_error", "the host adapter failed to complete the call")
        )
      end

      private

      # Contract order: a permanently removed retrieval mode or an unknown task
      # op answers kioku.unsupported_operation, everything else that fails the
      # frozen schema answers kioku.invalid_request, and only then is the
      # envelope completed and sealed.
      def decode(tool, arguments)
        args = Kioku::CanonicalJson.canonicalize(arguments)
        Kioku::ToolRequest.precheck!(tool: tool, arguments: args)
        @validator.validate!(tool, args)
        Kioku::ToolRequest.build(tool: tool, arguments: args)
      end

      def build_tool(tool)
        runner = self
        ::MCP::Tool.define(
          name: tool,
          description: Kioku::Schemas.description(tool),
          input_schema: @validator.schema_for(tool)
        ) do |server_context: nil, **arguments|
          runner.invoke(tool, arguments)
        end
      end

      # SDK-side argument validation is turned off because the SDK answers a
      # violation with an untyped sentence. Validator does the same checks and
      # answers with the frozen wire names instead.
      def configure_sdk
        logger = @logger
        ::MCP.configure do |config|
          config.validate_tool_call_arguments = false
          config.exception_reporter = lambda do |exception, context|
            logger.error("mcp sdk exception", error: exception.class.name, keys: context.keys.map(&:to_s))
          end
        end
      end
    end
  end
end
