# frozen_string_literal: true

require_relative "renderer"
require_relative "rules"
require_relative "validators/search"
require_relative "validators/fetch"
require_relative "validators/related"
require_relative "validators/remember"
require_relative "validators/feedback"
require_relative "validators/task"
require_relative "../envelope"
require_relative "../errors"

module Kioku
  module Mcp
    # One tool call: validate against the frozen contract, relay it over the host control
    # connection, and validate what came back before rendering it.
    #
    # "The MCP adapter holds no storage authority" [contracts:
    # envelope.transport_and_actor], so nothing here answers from itself. Argument
    # validation happens before any host round-trip, which is why a malformed call is
    # refused by its frozen wire name whether or not the core is running.
    class Dispatch
      VALIDATORS = {
        "context_search" => Validators::Search,
        "context_fetch" => Validators::Fetch,
        "context_related" => Validators::Related,
        "context_remember" => Validators::Remember,
        "context_feedback" => Validators::Feedback,
        "context_task" => Validators::Task
      }.freeze

      def initialize(link:, logger:)
        @link = link
        @logger = logger
      end

      def call(tool:, arguments:)
        payload = Rules.stringify(arguments)
        envelope = VALIDATORS.fetch(tool).new.call(arguments: payload)
        Renderer.success(relay(tool, payload, envelope))
      rescue Kioku::Error => e
        refuse(tool, e, payload)
      rescue StandardError => e
        internal_failure(tool, e, payload)
      end

      private

      def relay(tool, payload, envelope)
        frame = { "op" => "tool_call", "tool" => tool, "request" => payload }
        response = @link.call(frame: frame, deadline_ms: envelope.deadline_ms)

        Kioku::Envelope.parse_response(response, expected_request_id: envelope.request_id).payload
      end

      # The refusal names the tool and its wire name only. The remembered body, the query
      # and every other caller value stay out of both the response and the diagnostic
      # [contracts: response_fields.error; plan §9].
      def refuse(tool, error, payload)
        @logger.warn("#{tool} refused: #{error.code}")

        Renderer.refusal(error, request_id: echoed_request_id(payload))
      end

      def internal_failure(tool, error, payload)
        @logger.error("#{tool} failed in the host adapter: #{error.class}")
        refuse(tool,
               Kioku::Error.new("kioku.internal_error",
                                message: "the host adapter could not complete the call"),
               payload)
      end

      def echoed_request_id(payload)
        value = payload.is_a?(Hash) ? payload.dig("envelope", "request_id") : nil
        value.is_a?(String) ? value : nil
      end
    end
  end
end
