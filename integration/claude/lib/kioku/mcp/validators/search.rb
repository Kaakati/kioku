# frozen_string_literal: true

require_relative "../rules"
require_relative "../vocabulary"
require_relative "../../envelope"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_search]. The three retrieval mechanisms are the whole
      # set; mode=semantic and mode=hybrid are permanently unsupported values rather than
      # absent ones, so a caller that asks for them is told so by name instead of being
      # told its request was malformed.
      class Search
        PERMITTED = %w[envelope mode query keys seeds edge_kinds].freeze

        def call(arguments:)
          Rules.only(arguments, PERMITTED)
          mode = retrieval_mode(arguments)
          envelope = Kioku::Envelope.parse_request(arguments["envelope"])
          validate_inputs(mode, arguments)
          envelope
        end

        private

        def retrieval_mode(arguments)
          declared = arguments["mode"]
          if Vocabulary::REMOVED_RETRIEVAL_MODES.include?(declared)
            Rules.unsupported!("embedding-based retrieval is out of scope for this contract",
                               "mode" => declared)
          end

          Rules.enum(arguments, "mode", Vocabulary::RETRIEVAL_MODES)
        end

        def validate_inputs(mode, arguments)
          case mode
          when "exact" then Rules.typed_handles(arguments, "keys", min: 1, max: 50)
          when "lexical" then Rules.text(arguments, "query", max: 1024)
          when "related" then validate_traversal(arguments)
          end
        end

        def validate_traversal(arguments)
          Rules.typed_handles(arguments, "seeds", min: 1, max: 10)
          Rules.edge_kinds(arguments, "edge_kinds", Vocabulary::EDGE_KINDS)
        end
      end
    end
  end
end
