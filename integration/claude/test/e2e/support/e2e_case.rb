# frozen_string_literal: true

require "socket"

require_relative "agent_process"
require "kioku/agent/spool"
require "kioku/request_digest"

module Kioku
  module TestSupport
    # Shared arrangement for the end-to-end cases: a real bin/context-agent on a
    # real private Unix socket, and a real bin/context-mcp speaking real
    # JSON-RPC over real stdio to it.
    #
    # Nothing here stands in for a component. The only thing these cases vary is
    # whether the core at KIOKU_CORE_URL answers, because that is the whole of
    # the `queued` / `saved` distinction: "queued means durable host enqueue
    # only; saved means canonical commit" [contracts: notes; plan invariant 2].
    module E2eCase
      def with_agent(core_url:, bridge_token: "unused-in-this-case")
        Dir.mktmpdir("kioku-e2e") do |dir|
          spool_dir = File.join(dir, "spool")
          FileUtils.mkdir_p(spool_dir)
          agent = start_agent(File.join(dir, "agent.sock"), spool_dir, core_url, bridge_token)
          begin
            yield(agent)
          ensure
            agent.stop
          end
        end
      end

      def start_agent(socket_path, spool_dir, core_url, bridge_token)
        unless AgentProcess.available?
          flunk("#{AgentProcess.binary_path} does not exist. context-mcp reaches the core only " \
                "through the host agent (plan §3.1: the agent initiates the control connection " \
                "and the host exposes no other inbound service), so without it the two halves " \
                "of the system have no path between them.")
        end

        AgentProcess.new(socket_path: socket_path, spool_dir: spool_dir,
                         core_url: core_url, bridge_token: bridge_token).start
      end

      # A real context-mcp process bound to this agent's socket.
      def with_mcp(agent)
        server = StdioServer.new("context-mcp", env: { "KIOKU_SOCKET_PATH" => agent.socket_path })
                            .handshake
        begin
          yield(server)
        ensure
          server.close
        end
      end

      # The frozen context_remember argument set, carrying a request_digest
      # computed over the call itself by the host's own canonicalization.
      def remember_arguments(project_key:, object_key:, idempotency_key:,
                             title: "Invoice retry fails under concurrent workers",
                             body: "Two workers claimed the same invoice lease; the retry double-charged.")
        arguments = {
          "envelope" => {
            "schema_version" => "kioku.tool.v1",
            "request_id" => uuid_v7,
            "deadline_ms" => 5_000,
            "scope" => { "store" => "project", "project_key" => project_key },
            "idempotency_key" => idempotency_key
          },
          "kind" => "decision",
          "destination" => { "store_kind" => "project", "project_key" => project_key },
          "title" => title,
          "body" => body,
          "evidence" => [{ "ref" => { "object_key" => object_key }, "relation" => "supports" }]
        }
        digest = Kioku::RequestDigest.compute(arguments)
        arguments["envelope"] = arguments["envelope"].merge("request_digest" => digest)
        arguments
      end

      # A TCP port on loopback that nothing is listening on: the honest way to
      # say "the core is unreachable" without stopping anybody's stack.
      def unreachable_core_url
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        server.close
        "http://127.0.0.1:#{port}"
      end

      def spool_at(dir)
        Kioku::Agent::Spool.new(dir: dir)
      end

      def envelope_of(message, agent, context)
        envelope = McpResult.envelope(message)
        return envelope unless envelope.nil?

        flunk("#{context}: the MCP result carried no Kioku response envelope: " \
              "#{JSON.generate(message)[0, 600]} (agent stderr: #{agent.diagnostics[0, 600].inspect})")
      end
    end
  end
end
