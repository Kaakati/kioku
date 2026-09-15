# frozen_string_literal: true

require "mcp"

module Kioku
  module Mcp
    # The SDK stdio transport, with a diagnostic for frames it cannot parse.
    #
    # A malformed frame still gets its JSON-RPC error response on stdout, but the SDK
    # emits nothing anywhere saying what arrived. "diagnostics use stderr" [plan §3], and
    # an operator debugging a corrupted stream needs to see that the corruption was on
    # the way in.
    class StdioTransport < ::MCP::Server::Transports::StdioTransport
      def initialize(server, logger:)
        super(server)
        @logger = logger
      end

      private

      def parse_line(line)
        parsed = super
        @logger.warn("rejected a malformed stdin frame of #{line.bytesize} bytes") if parsed.nil?
        parsed
      end
    end
  end
end
