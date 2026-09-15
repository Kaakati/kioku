# frozen_string_literal: true

require_relative "../rules"
require_relative "../vocabulary"
require_relative "../../envelope"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_fetch]. Batches are bounded at both ends: an empty batch
      # is as malformed as an oversized one, because a fetch names what it wants.
      class Fetch
        PERMITTED = %w[envelope handles].freeze

        def call(arguments:)
          Rules.only(arguments, PERMITTED)
          envelope = Kioku::Envelope.parse_request(arguments["envelope"])
          validate_handles(arguments)
          envelope
        end

        private

        def validate_handles(arguments)
          handles = Rules.typed_handles(arguments, "handles", min: 1, max: 50)
          handles.each_with_index do |handle, index|
            next if Vocabulary::FETCH_HANDLE_KINDS.include?(handle["kind"])

            Rules.invalid!("handles[#{index}].kind must be one of: " \
                           "#{Vocabulary::FETCH_HANDLE_KINDS.join(', ')}")
          end
        end
      end
    end
  end
end
