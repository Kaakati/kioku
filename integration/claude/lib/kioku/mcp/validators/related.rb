# frozen_string_literal: true

require_relative "../rules"
require_relative "../vocabulary"
require_relative "../../envelope"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_related]. edge_kinds is required rather than defaulted,
      # so no call can request an untyped walk, and the hop ceiling is a contract limit
      # rather than a tuning knob: "Covers ... hops > 2"
      # [contracts: errors kioku.unsupported_operation].
      class Related
        PERMITTED = %w[envelope seeds edge_kinds direction max_hops].freeze

        def call(arguments:)
          Rules.only(arguments, PERMITTED)
          envelope = Kioku::Envelope.parse_request(arguments["envelope"])
          Rules.typed_handles(arguments, "seeds", min: 1, max: 10)
          Rules.edge_kinds(arguments, "edge_kinds", Vocabulary::EDGE_KINDS)
          Rules.enum(arguments, "direction", Vocabulary::TRAVERSAL_DIRECTIONS)
          validate_max_hops(arguments)
          envelope
        end

        private

        def validate_max_hops(arguments)
          return if arguments["max_hops"].nil?

          hops = Rules.integer(arguments, "max_hops", minimum: 1)
          return hops unless hops > Vocabulary::MAX_HOPS

          Rules.unsupported!("traversal deeper than #{Vocabulary::MAX_HOPS} hops is not supported",
                             "max_hops" => hops)
        end
      end
    end
  end
end
