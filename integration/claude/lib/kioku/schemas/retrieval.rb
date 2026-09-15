# frozen_string_literal: true

module Kioku
  module Schemas
    # context_search, context_fetch and context_related: the three read tools.
    module Retrieval
      # exact, lexical and related are the only retrieval mechanisms. semantic
      # and hybrid are permanently unsupported -- embeddings, vector search and
      # hybrid search are out of scope, not deferred -- and a caller that asks
      # for one gets kioku.unsupported_operation.
      MODES = %w[exact lexical related solutions].freeze
      PROFILES = %w[mixed memory code evidence solutions].freeze
      REMOVED_MODES = %w[semantic hybrid].freeze

      module_function

      def search
        {
          "type" => "object",
          "properties" => search_properties,
          "required" => %w[envelope mode],
          "additionalProperties" => false,
          "allOf" => search_conditions
        }
      end

      def search_properties
        common = Kioku::Schemas::Common
        {
          "envelope" => common.envelope(mutation: false),
          "mode" => mode_property,
          "query" => { "type" => "string", "minLength" => 1, "maxLength" => 1024,
                       "description" => "Required when mode=lexical." },
          "keys" => key_array, "seeds" => seed_array(50), "edge_kinds" => edge_kinds_property(18),
          "profile" => { "type" => "string", "enum" => PROFILES,
                         "description" => "Subject routing. profile=solutions returns retained cases with " \
                                          "their preconditions, contrary evidence and rejected attempts." },
          "filters" => search_filters, "expand" => expand_property,
          "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 50 },
          "candidate_limit" => { "type" => "integer", "minimum" => 1, "maximum" => 200 },
          "facets" => facets_property, "highlight" => highlight_property,
          "include_disputed" => include_disputed_property,
          "require_source_validation" => require_validation_property,
          "order" => { "type" => "string", "enum" => %w[relevance recorded_at valid_from] },
          "cursor" => common.cursor
        }
      end

      def mode_property
        { "type" => "string", "enum" => MODES,
          "description" => "exact = direct key/path/symbol lookup, bypassing ranking. " \
                           "lexical = ParadeDB BM25 over versioned search documents. " \
                           "related = bounded typed traversal from resolved seeds. " \
                           "solutions is a deprecated alias for mode=lexical with profile=solutions. " \
                           "semantic and hybrid do not exist here." }
      end

      def search_conditions
        [
          condition("lexical", ["query"]),
          condition("exact", ["keys"]),
          condition("related", %w[seeds edge_kinds])
        ]
      end

      def condition(mode, required)
        { "if" => { "properties" => { "mode" => { "const" => mode } }, "required" => ["mode"] },
          "then" => { "required" => required } }
      end

      def key_array
        { "type" => "array", "minItems" => 1, "maxItems" => 50,
          "description" => "Required when mode=exact.",
          "items" => Kioku::Schemas::Common.typed_handle(
            Kioku::Schemas::Common::SEARCH_KEY_KINDS, "An exact typed handle or locator."
          ) }
      end

      def seed_array(max_items)
        { "type" => "array", "minItems" => 1, "maxItems" => max_items,
          "description" => "Traversal origins.",
          "items" => Kioku::Schemas::Common.typed_handle(
            Kioku::Schemas::Common::SEED_KINDS, "An authorized traversal seed."
          ) }
      end

      def edge_kinds_property(max_items)
        { "type" => "array", "minItems" => 1, "maxItems" => max_items,
          "description" => "Validated edge vocabulary. An unlisted name returns kioku.unsupported_operation.",
          "items" => { "type" => "string", "enum" => Kioku::Schemas::Common::EDGE_KINDS } }
      end

      def search_filters
        common = Kioku::Schemas::Common
        { "type" => "object", "additionalProperties" => false,
          "properties" => {
            "store_kind" => enum_array(%w[project global]),
            "global_categories" => enum_array(Kioku::Envelope::GLOBAL_CATEGORIES),
            "memory_kinds" => enum_array(Kioku::Schemas::Memory::KINDS),
            "lifecycle" => enum_array(common::LIFECYCLES),
            "authority" => enum_array(common::AUTHORITIES),
            "availability" => enum_array(common::AVAILABILITIES),
            "language" => common.string_array("Language filter."),
            "repository_key" => common.string_array("Repository filter."),
            "worktree_key" => common.string_array("Worktree filter."),
            "task_key" => common.string_array("Task filter."),
            "valid_at" => { "type" => "string", "description" => "RFC3339 valid-time instant." },
            "has_open_dispute" => { "type" => "boolean" },
            "source_view" => { "type" => "string", "enum" => Kioku::Envelope::SOURCE_VIEWS },
            "commit_oid" => { "type" => "string" } } }
      end

      def expand_property
        { "type" => "object", "additionalProperties" => false,
          "description" => "Bounded neighbour expansion for mode=exact and mode=lexical.",
          "properties" => {
            "hops" => { "type" => "integer", "minimum" => 0, "maximum" => 2 },
            "fanout" => { "type" => "integer", "minimum" => 1 },
            "max_visited_edges" => { "type" => "integer", "minimum" => 1 },
            "edge_kinds" => edge_kinds_property(18) } }
      end

      def facets_property
        { "type" => "array",
          "description" => "Requested facet dimensions. Traversal-expanded results are labelled " \
                           "bounded_candidate_pool, never the declared match set.",
          "items" => { "type" => "string",
                       "enum" => %w[kind store_kind category language lifecycle repository author_authority] } }
      end

      def highlight_property
        { "type" => "boolean",
          "description" => "Snippet previews. Automatically disabled for fuzzy queries with warning " \
                           "highlight_unsupported. A snippet is a preview, never an evidence handle." }
      end

      def include_disputed_property
        { "type" => "boolean",
          "description" => "When false, disputed factual assertions are suppressed from confident " \
                           "delivery but governing user decisions still return with the objection attached." }
      end

      def require_validation_property
        { "type" => "boolean",
          "description" => "When true, an unvalidatable dependency returns kioku.source_unavailable " \
                           "instead of an applicability=unknown label." }
      end

      def fetch
        common = Kioku::Schemas::Common
        { "type" => "object", "required" => %w[envelope handles], "additionalProperties" => false,
          "properties" => {
            "envelope" => common.envelope(mutation: false),
            "handles" => { "type" => "array", "minItems" => 1, "maxItems" => 50,
                           "items" => common.typed_handle(common::FETCH_HANDLE_KINDS,
                                                          "An already-identified handle.") },
            "ranges" => ranges_property,
            "max_bytes_per_handle" => { "type" => "integer", "minimum" => 1 },
            "format" => { "type" => "string", "enum" => %w[text structured] },
            "include_provenance" => { "type" => "boolean" },
            "revalidate_source" => { "type" => "boolean",
                                     "description" => "Batch host check of selected dependencies " \
                                                      "under the caller deadline." },
            "as_of_revision" => { "type" => "integer", "minimum" => 1,
                                  "description" => "Historical content is always labelled applicability=historical." },
            "cursor" => common.cursor } }
      end

      def ranges_property
        { "type" => "object",
          "description" => "Per-handle sub-ranges keyed by handle key. An out-of-range request is " \
                           "truncated and reported in coverage, never silently clamped.",
          "additionalProperties" => {
            "type" => "object", "additionalProperties" => false,
            "properties" => {
              "byte_start" => { "type" => "integer", "minimum" => 0 },
              "byte_end" => { "type" => "integer", "minimum" => 0 },
              "line_start" => { "type" => "integer", "minimum" => 1 },
              "line_end" => { "type" => "integer", "minimum" => 1 } } } }
      end

      def related
        common = Kioku::Schemas::Common
        { "type" => "object", "required" => %w[envelope seeds edge_kinds direction],
          "additionalProperties" => false, "properties" => related_properties(common) }
      end

      def related_properties(common)
        {
          "envelope" => common.envelope(mutation: false),
          "seeds" => seed_array(10),
          "edge_kinds" => edge_kinds_property(8),
          "direction" => { "type" => "string", "enum" => %w[out in both] },
          "max_hops" => { "type" => "integer", "minimum" => 1, "maximum" => 2,
                          "description" => "Two hops maximum. More returns kioku.unsupported_operation." },
          "fanout" => { "type" => "integer", "minimum" => 1 },
          "max_visited_edges" => { "type" => "integer", "minimum" => 1 },
          "filters" => related_filters(common),
          "include_unresolved_targets" => { "type" => "boolean" },
          "diversity" => diversity_property,
          "require_source_validation" => require_validation_property,
          "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 200 },
          "cursor" => common.cursor
        }
      end

      def related_filters(common)
        { "type" => "object", "additionalProperties" => false,
          "properties" => {
            "repository_key" => common.string_array("Repository filter."),
            "worktree_key" => common.string_array("Worktree filter."),
            "language" => common.string_array("Language filter."),
            "lifecycle" => enum_array(common::LIFECYCLES),
            "memory_kinds" => enum_array(Kioku::Schemas::Memory::KINDS),
            "resolution_basis" => enum_array(%w[syntactic convention semantic]),
            "source_view" => { "type" => "string", "enum" => Kioku::Envelope::SOURCE_VIEWS },
            "commit_oid" => { "type" => "string" } } }
      end

      def diversity_property
        { "type" => "object", "additionalProperties" => false,
          "description" => "Keeps high-degree utility symbols from dominating a traversal.",
          "properties" => {
            "max_per_node" => { "type" => "integer", "minimum" => 1 },
            "suppress_high_degree_above" => { "type" => "integer", "minimum" => 1 } } }
      end

      def enum_array(values)
        { "type" => "array", "items" => { "type" => "string", "enum" => values } }
      end
    end
  end
end
