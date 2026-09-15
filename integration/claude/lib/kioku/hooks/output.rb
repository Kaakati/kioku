# frozen_string_literal: true

require "json"

module Kioku
  module Hooks
    # Event-specific hook output.
    #
    # Only the two events with a documented additional-context contract emit
    # anything on stdout. Every other event writes nothing at all: the events do
    # not share an output contract, and inventing one would corrupt a session
    # rather than enrich it. These shapes must be requalified against the
    # installed Claude Code client before they are relied on.
    #
    # Nothing here ever emits a permission decision or a blocking result. A
    # memory subsystem that cannot reach its core must let normal work continue.
    module Output
      ENHANCEABLE_EVENTS = %w[SessionStart UserPromptSubmit].freeze
      CONTEXT_LIMIT = 8_192

      module_function

      # Returns the JSON line to print, or nil when the hook adds nothing.
      # Adding nothing is a valid result.
      def render(event, capsule)
        return nil unless ENHANCEABLE_EVENTS.include?(event)

        text = additional_context(capsule)
        return nil if text.nil? || text.strip.empty?

        JSON.generate(
          "hookSpecificOutput" => {
            "hookEventName" => event,
            "additionalContext" => text.byteslice(0, CONTEXT_LIMIT).to_s.scrub
          }
        )
      end

      def additional_context(capsule)
        return nil unless capsule.is_a?(Hash)
        return nil if Kioku::FAILED_STATUSES.include?(capsule["status"])

        data = capsule["data"]
        candidate = data.is_a?(Hash) ? data["additional_context"] : nil
        candidate.is_a?(String) ? candidate : nil
      end
    end
  end
end
