# frozen_string_literal: true

require "time"

module Kioku
  module Agent
    # Dispatch for the private Unix socket. Every op is named and bounded;
    # there is no pass-through command, no shell and no SQL surface.
    class Router
      OPS = %w[
        agent.health tool.call capture.record capsule.build binding.resolve
        source.manifest source.read source.validate spool.status spool.replay
      ].freeze

      def initialize(context)
        @context = context
      end

      def call(op, payload, deadline_ms)
        raise Kioku.unsupported_operation("unknown agent op", { "requested" => op }) unless OPS.include?(op)

        send(op.tr(".", "_").to_sym, payload || {}, deadline_ms)
      end

      private

      def agent_health(_payload, _deadline_ms)
        {
          "ok" => true, "version" => Kioku::VERSION, "protocol" => Kioku::FRAME_PROTOCOL,
          "control" => @context.control.state, "spool" => @context.spool.stats,
          "approved_roots" => @context.roots.roots.length,
          "unresolved_roots" => @context.roots.unresolved,
          "server_time" => Time.now.utc.iso8601(3)
        }
      end

      # Forwards a tool call to the core. A mutation that cannot reach the core
      # is durably spooled and answered queued; a read is not faked.
      def tool_call(payload, deadline_ms)
        tool = payload["tool"]
        envelope = payload["envelope"] || {}
        arguments = payload["arguments"] || {}
        @context.bridge.tool_call(tool: tool, envelope: envelope, arguments: arguments,
                                  deadline_ms: deadline_ms)
      rescue Kioku::TransportUnavailable => e
        raise e unless Kioku.mutation?(tool, arguments)

        queued(payload, envelope, spool_call(payload, envelope))
      end

      def spool_call(payload, envelope)
        @context.spool.enqueue(
          kind: payload["tool"], payload: payload,
          binding_state: envelope.dig("scope", "project_key") ? "declared" : "unresolved"
        )
      end

      # Bounded capture from a hook. It is enqueued durably and reported as
      # queued; capture never claims a canonical save.
      def capture_record(payload, _deadline_ms)
        binding = @context.binding.resolve(payload["cwd"])
        receipt = @context.spool.enqueue(
          kind: "capture", binding_state: binding["state"],
          payload: payload.merge("binding" => binding)
        )
        { "status" => "queued", "data" => { "saved" => false, "spool" => receipt.to_h, "binding" => binding } }
      end

      # The bounded context capsule for SessionStart and UserPromptSubmit. When
      # the core cannot answer in the hook budget the hook adds nothing, which
      # is a valid result.
      def capsule_build(payload, deadline_ms)
        binding = @context.binding.resolve(payload["cwd"])
        body = payload.merge("binding" => binding, "agent_version" => Kioku::VERSION)
        @context.bridge.capsule(payload: body, deadline_ms: deadline_ms)
      end

      def binding_resolve(payload, _deadline_ms)
        @context.binding.resolve(payload["cwd"])
      end

      def source_manifest(payload, _deadline_ms)
        @context.source.manifest(path: payload["path"])
      end

      def source_read(payload, _deadline_ms)
        @context.source.read(
          path: payload["path"],
          max_bytes: payload.fetch("max_bytes", Kioku::SourceReader::MAX_READ_BYTES),
          byte_start: payload.fetch("byte_start", 0)
        )
      end

      def source_validate(payload, _deadline_ms)
        paths = Array(payload["paths"]).first(200)
        { "results" => paths.map { |item| validate_one(item) } }
      end

      def validate_one(item)
        @context.source.validate(path: item["path"], expected_hash: item["expected_hash"])
      end

      def spool_status(_payload, _deadline_ms)
        @context.spool.stats
      end

      def spool_replay(_payload, _deadline_ms)
        @context.replay.run_once
      end

      def queued(payload, envelope, receipt)
        {
          "schema_version" => Kioku::SCHEMA_VERSION,
          "request_id" => envelope["request_id"],
          "status" => "queued",
          "error" => Kioku::Error.new("kioku.queued",
                                      "durably enqueued on the host spool; not committed and not saved",
                                      retry_after_ms: 5_000).to_error_object,
          "data" => { "saved" => false, "spool" => receipt.to_h },
          "receipt" => { "receipt_id" => receipt.spool_entry_id,
                         "idempotency_key" => envelope["idempotency_key"],
                         "request_digest" => envelope["request_digest"],
                         "committed_at" => nil, "replayed" => false },
          "warnings" => [{ "code" => "host_disconnected", "detail" => "core unreachable", "count" => 1 }],
          "server_time" => Time.now.utc.iso8601(3)
        }.tap { |body| body["data"]["tool"] = payload["tool"] }
      end
    end
  end
end
