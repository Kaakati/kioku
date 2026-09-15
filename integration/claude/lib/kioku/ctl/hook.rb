# frozen_string_literal: true

require "json"

require_relative "../errors"

module Kioku
  module Ctl
    # The Claude Code hook client.
    #
    # "Hooks perform bounded work ... Optional enhancement failure must allow normal
    # Claude work to continue" [plan invariant 10]; "Core down | Optional hooks return
    # without enhancement" [plan §9]; "The one-second hook timeout is an outer guard; the
    # CLI enforces the shorter operation deadline internally" [research Appendix B].
    #
    # stdin is bounded: the hook stops reading at its limit and exits rather than
    # buffering whatever a transcript or a runaway tool result happens to be. stdout
    # carries event output only, and only output the hook actually has; every diagnostic
    # goes to stderr.
    class Hook
      MAX_INPUT_BYTES = 256 * 1024
      DELIVERY_DEADLINE_MS = 500
      EXIT_OK = 0

      # The frozen event list [research §11 / Appendix B].
      SUPPORTED_EVENTS = %w[
        SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure
        SubagentStart SubagentStop PreCompact PostCompact Stop SessionEnd
      ].freeze

      def initialize(stdin:, stdout:, logger:, link:)
        @stdin = stdin
        @stdout = stdout
        @logger = logger
        @link = link
      end

      # A hook never blocks the user's turn: exit status 2 is the blocking status in the
      # hook contract, and no failure here produces it.
      def call
        payload = read_payload
        return EXIT_OK if payload.nil?

        event = supported_event(payload)
        return EXIT_OK if event.nil?

        deliver(event, payload)
        EXIT_OK
      end

      private

      def read_payload
        @stdin.binmode
        raw = @stdin.read(MAX_INPUT_BYTES + 1)
        return refuse("the hook received no input on stdin") if raw.nil? || raw.strip.empty?
        return refuse("hook input exceeded #{MAX_INPUT_BYTES} bytes and was not decoded") if
          raw.bytesize > MAX_INPUT_BYTES

        decode(raw)
      end

      def decode(raw)
        payload = JSON.parse(raw)
        return payload if payload.is_a?(Hash)

        refuse("hook input is not an event object")
      rescue JSON::ParserError
        refuse("hook input is not valid JSON")
      end

      def supported_event(payload)
        name = payload["hook_event_name"]
        return refuse("hook input names no event") unless name.is_a?(String) && !name.strip.empty?
        return refuse("#{name} is not an event this host package handles") unless
          SUPPORTED_EVENTS.include?(name)

        name
      end

      # "The hook client validates bounded input and forwards an envelope to the host
      # agent" [plan §7.1 step 1]. Durability is the agent's spool to report; a hook that
      # could not reach the agent says so and claims nothing.
      def deliver(event, payload)
        frame = { "op" => "hook_event", "event" => event, "payload" => payload }
        emit(event, @link.call(frame: frame, deadline_ms: DELIVERY_DEADLINE_MS))
      rescue Kioku::Error => e
        @logger.warn("#{event} was not delivered to the host agent: #{e.code}")
      end

      def emit(event, response)
        context = response.is_a?(Hash) ? response["additional_context"] : nil
        return unless context.is_a?(String) && !context.strip.empty?

        @stdout.puts(JSON.generate("hookSpecificOutput" => { "hookEventName" => event,
                                                             "additionalContext" => context }))
      end

      def refuse(detail)
        @logger.warn(detail)
        nil
      end
    end
  end
end
