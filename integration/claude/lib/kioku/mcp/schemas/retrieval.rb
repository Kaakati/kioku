# frozen_string_literal: true

require_relative "shared"

module Kioku
  module Mcp
    module Schemas
      # The three read tools [contracts: tools context_search / context_fetch /
      # context_related].
      module Retrieval
        module_function

        def search
          Shared.closed_object(
            %w[envelope mode],
            "envelope" => Shared.envelope,
            "mode" => Shared.enum(Vocabulary::RETRIEVAL_MODES),
            "query" => Shared.string(max: 1024),
            "keys" => Shared.array(Shared.typed_handle, min: 1, max: 50),
            "seeds" => Shared.array(Shared.typed_handle, min: 1, max: 10),
            "edge_kinds" => Shared.array(Shared.enum(Vocabulary::EDGE_KINDS), min: 1, max: 8)
          )
        end

        def fetch
          Shared.closed_object(
            %w[envelope handles],
            "envelope" => Shared.envelope,
            "handles" => Shared.array(Shared.fetch_handle, min: 1, max: 50)
          )
        end

        def related
          Shared.closed_object(
            %w[envelope seeds edge_kinds direction],
            "envelope" => Shared.envelope,
            "seeds" => Shared.array(Shared.typed_handle, min: 1, max: 10),
            "edge_kinds" => Shared.array(Shared.enum(Vocabulary::EDGE_KINDS), min: 1, max: 8),
            "direction" => Shared.enum(Vocabulary::TRAVERSAL_DIRECTIONS),
            "max_hops" => { "type" => "integer", "minimum" => 1,
                            "maximum" => Vocabulary::MAX_HOPS, "default" => 1 }
          )
        end
      end
    end
  end
end
