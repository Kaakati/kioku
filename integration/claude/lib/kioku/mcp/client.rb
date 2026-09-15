# frozen_string_literal: true

require "time"

module Kioku
  module Mcp
    # Forwards one prepared tool request to context-agent over the private Unix
    # socket and returns the response body.
    #
    # This adapter holds no storage authority. When the agent is unreachable it
    # does not invent a result: a read fails visibly, and a mutation is written
    # to the same durable host spool the agent uses and answered `queued` with a
    # spool receipt carrying saved=false. Nothing here can ever answer `saved`.
    class Client
      def initialize(config:, logger:)
        @config = config
        @logger = logger
        @socket = Kioku::SocketClient.new(
          path: config.socket_path, connect_timeout_ms: config.connect_timeout_ms, logger: logger
        )
      end

      def call(request)
        @socket.call(op: "tool.call", payload: request.payload, deadline_ms: request.socket_deadline_ms)
      rescue Kioku::TransportUnavailable => e
        @logger.warn("context-agent unavailable", tool: request.tool, reason: e.message)
        degrade(request, e)
      end

      def close
        @socket.close
      end

      private

      def degrade(request, error)
        return spool(request) if request.mutation?

        raise error
      end

      def spool(request)
        receipt = Kioku.spool_for(@config).enqueue(
          kind: request.tool,
          payload: request.payload,
          binding_state: binding_state(request)
        )
        queued_response(request, receipt)
      end

      def binding_state(request)
        request.envelope.dig("scope", "project_key") ? "declared" : "unresolved"
      end

      # kioku.queued: durably enqueued on the host, not committed. Replay after
      # reconnect returns the same idempotency receipt.
      def queued_response(request, receipt)
        {
          "schema_version" => Kioku::SCHEMA_VERSION,
          "request_id" => request.envelope["request_id"],
          "status" => "queued",
          "error" => queued_error,
          "data" => { "saved" => false, "spool" => receipt.to_h },
          "receipt" => spool_receipt(request, receipt),
          "warnings" => [{ "code" => "host_disconnected", "detail" => "context-agent unreachable", "count" => 1 }],
          "server_time" => Time.now.utc.iso8601(3)
        }
      end

      def queued_error
        Kioku::Error.new(
          "kioku.queued",
          "durably enqueued on the host spool; not committed and not saved",
          retry_after_ms: 5_000
        ).to_error_object
      end

      def spool_receipt(request, receipt)
        {
          "receipt_id" => receipt.spool_entry_id,
          "idempotency_key" => request.envelope["idempotency_key"],
          "request_digest" => request.envelope["request_digest"],
          "committed_at" => nil,
          "replayed" => false
        }
      end
    end
  end
end
