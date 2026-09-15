# frozen_string_literal: true

require "digest"
require "time"

module Kioku
  module Hooks
    # Builds the bounded capture record for one hook event.
    #
    # A hook never ships a transcript, a whole tool payload or a file's
    # contents. It ships identity, correlation and short explicitly truncated
    # excerpts, with a digest of the full value so the core can recognise the
    # same input later without the host having sent it.
    module Capture
      EXCERPT_LIMIT = 2_048
      PROMPT_LIMIT = 4_096
      IDENTITY_FIELDS = %w[session_id transcript_path cwd hook_event_name source reason
                           tool_name tool_use_id permission_mode stop_hook_active].freeze
      EXCERPT_FIELDS = { "prompt" => PROMPT_LIMIT, "tool_input" => EXCERPT_LIMIT,
                         "tool_response" => EXCERPT_LIMIT, "message" => EXCERPT_LIMIT }.freeze

      module_function

      def build(payload)
        identity(payload).merge(
          "captured_at" => Time.now.utc.iso8601(3),
          "agent_version" => Kioku::VERSION,
          "excerpts" => excerpts(payload),
          "correlation" => correlation(payload)
        )
      end

      def identity(payload)
        IDENTITY_FIELDS.each_with_object({}) do |field, out|
          value = payload[field]
          out[field] = value unless value.nil?
        end
      end

      def excerpts(payload)
        EXCERPT_FIELDS.each_with_object({}) do |(field, limit), out|
          value = payload[field]
          next if value.nil?

          out[field] = excerpt(value, limit)
        end
      end

      def excerpt(value, limit)
        text = value.is_a?(String) ? value : JSON.generate(value)
        {
          "text" => text.byteslice(0, limit).to_s.scrub,
          "truncated" => text.bytesize > limit,
          "total_bytes" => text.bytesize,
          "content_hash" => "sha256:#{Digest::SHA256.hexdigest(text)}"
        }
      end

      # Correlation hints only. An unjoinable hint leaves attribution
      # unresolved at the core; nothing is inferred from timing or process id.
      def correlation(payload)
        {
          "session_id" => payload["session_id"],
          "prompt_id" => payload["prompt_id"],
          "tool_use_id" => payload["tool_use_id"],
          "agent_key" => payload["agent_id"] || payload["subagent_id"]
        }.compact
      end
    end
  end
end
