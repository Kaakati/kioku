# frozen_string_literal: true

require_relative "capture"
require_relative "output"

module Kioku
  module Hooks
    # Hook dispatch for bin/contextctl.
    #
    # The contract this class keeps is simple and absolute: a hook never blocks
    # Claude and never fails the session. Every path exits 0, stdout carries
    # only the event's own output contract, and everything else goes to stderr.
    # If the agent or the core is unreachable, the hook returns without
    # enhancement and normal work continues.
    class Dispatcher
      # capture: eligible for the durable spool. enhance: has a documented
      # additional-context contract.
      EVENTS = {
        "SessionStart" => { capture: true, enhance: true },
        "UserPromptSubmit" => { capture: true, enhance: true },
        "PreToolUse" => { capture: false, enhance: false },
        "PostToolUse" => { capture: true, enhance: false },
        "PostToolUseFailure" => { capture: true, enhance: false },
        "SubagentStart" => { capture: true, enhance: false },
        "SubagentStop" => { capture: true, enhance: false },
        "PreCompact" => { capture: true, enhance: false },
        "PostCompact" => { capture: true, enhance: false },
        "Stop" => { capture: true, enhance: false },
        "SessionEnd" => { capture: true, enhance: false }
      }.freeze

      CAPTURE_SHARE = 0.4

      def initialize(config:, logger:, stdin: $stdin, stdout: $stdout)
        @config = config
        @logger = logger
        @stdin = stdin
        @stdout = stdout
        @client = Kioku::SocketClient.new(
          path: config.socket_path, connect_timeout_ms: config.connect_timeout_ms, logger: logger
        )
      end

      def run
        started = now
        payload = read_payload
        event = payload["hook_event_name"]
        behaviour = EVENTS[event]
        return skip(event) if behaviour.nil?

        dispatch(event, behaviour, payload, started)
        0
      rescue Kioku::Error => e
        @logger.warn("hook returned without enhancement", code: e.code, detail: e.message)
        0
      rescue StandardError => e
        @logger.error("hook failed", error: e.class.name, detail: e.message)
        0
      ensure
        @client.close
      end

      private

      def read_payload
        Kioku::BoundedIO.read_json(@stdin, timeout_ms: @config.hook_deadline_ms)
      end

      def skip(event)
        @logger.debug("no contract for hook event", event: event.to_s)
        0
      end

      def dispatch(event, behaviour, payload, started)
        capture(payload, budget(started, CAPTURE_SHARE)) if behaviour[:capture]
        return unless behaviour[:enhance]

        emit(Output.render(event, capsule(payload, budget(started, 1.0))))
      end

      def capture(payload, deadline_ms)
        return if deadline_ms <= 0

        @client.call(op: "capture.record", deadline_ms: deadline_ms,
                     payload: Capture.build(payload).merge("cwd" => payload["cwd"]))
      rescue Kioku::Error => e
        @logger.warn("capture not recorded", code: e.code)
      end

      def capsule(payload, deadline_ms)
        return nil if deadline_ms <= 0

        @client.call(op: "capsule.build", deadline_ms: deadline_ms, payload: capsule_payload(payload))
      rescue Kioku::Error => e
        @logger.warn("no capsule; hook adds nothing", code: e.code)
        nil
      end

      def capsule_payload(payload)
        {
          "cwd" => payload["cwd"],
          "event" => payload["hook_event_name"],
          "correlation" => Capture.correlation(payload),
          "token_budget" => 1_200
        }
      end

      def emit(line)
        return if line.nil?

        @stdout.puts(line)
        @stdout.flush
      end

      # Remaining milliseconds of the hook budget, optionally a share of it.
      def budget(started, share)
        elapsed_ms = ((now - started) * 1000).round
        ((@config.hook_deadline_ms - elapsed_ms) * share).round
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
