# frozen_string_literal: true

module Kioku
  module Schemas
    # Shared schema fragments. Every fragment is a method returning a fresh
    # hash rather than a $ref: the MCP SDK only accepts $ref in input schemas
    # from protocol version 2025-11-25 upward, and a client negotiating an
    # earlier version must still see a complete, self-describing schema.
    module Common
      EDGE_KINDS = %w[
        DEFINES IMPORTS REFERENCES MAY_CALL RESOLVES_TO IMPLEMENTS GENERATED_FROM
        CONSUMED_BY CONSTRAINS PROPOSED_FOR REJECTED_IN SUPERSEDES SUPPORTED_BY
        CONTRADICTS ASSESSES DERIVED_FROM OBSERVED_FRAME EXERCISED
      ].freeze

      SEARCH_KEY_KINDS = %w[memory_key task_key evidence_key symbol_key path error_signature identifier].freeze
      FETCH_HANDLE_KINDS = %w[
        memory_revision global_record_revision evidence object source_range
        commit diff observation report receipt packet
      ].freeze
      SEED_KINDS = %w[symbol_key path memory_key task_key candidate_version_key evidence_key commit_oid].freeze
      RELATIONS = %w[supports contradicts context].freeze
      LIFECYCLES = %w[proposed active superseded retracted].freeze
      AUTHORITIES = %w[user assistant tool system imported].freeze
      AVAILABILITIES = %w[available redacted missing expired].freeze

      module_function

      def scope
        {
          "type" => "object",
          "description" => "Requested scope. store=both is the default retrieval posture: " \
                           "the active project plus applicable global records. A global operation " \
                           "declares store=global explicitly; it is never reached by omitting project_key.",
          "properties" => {
            "store" => { "type" => "string", "enum" => Kioku::Envelope::STORES },
            "project_key" => { "type" => "string", "minLength" => 1,
                               "description" => "Required when store is project or both." },
            "repository_key" => { "type" => %w[string null] },
            "worktree_key" => { "type" => %w[string null] },
            "task_key" => { "type" => %w[string null],
                            "description" => "Narrows retrieval; does not authorize task mutation." },
            "cross_project_keys" => { "type" => "array", "items" => { "type" => "string" },
                                      "description" => "Each entry must be an explicitly granted scope." },
            "global_categories" => { "type" => "array",
                                     "items" => { "type" => "string",
                                                  "enum" => Kioku::Envelope::GLOBAL_CATEGORIES } },
            "source_view" => { "type" => "string", "enum" => Kioku::Envelope::SOURCE_VIEWS }
          },
          "required" => ["store"],
          "additionalProperties" => false
        }
      end

      def envelope(mutation:)
        {
          "type" => "object",
          "description" => envelope_description,
          "properties" => envelope_properties(mutation),
          "required" => ["scope"],
          "additionalProperties" => false
        }
      end

      def envelope_description
        "Common request envelope. The host adapter supplies schema_version, request_id, " \
          "deadline_ms and (for mutations) request_digest. Actor identity and authority are " \
          "derived by the core from the authenticated transport: supplying authority, " \
          "actor_principal_id, origin_role or identity is rejected with kioku.invalid_request."
      end

      def envelope_properties(mutation)
        base = {
          "scope" => scope,
          "deadline_ms" => { "type" => "integer", "minimum" => 1, "maximum" => 30_000,
                             "description" => "Relative budget in milliseconds, clamped per tool." },
          "token_budget" => { "type" => "integer", "minimum" => 1,
                              "description" => "Estimated tokens. Explicit search 600-1200; evidence fetch 1500." },
          "correlation" => correlation,
          "client" => { "type" => "object",
                        "properties" => { "name" => { "type" => "string" }, "version" => { "type" => "string" } },
                        "additionalProperties" => false },
          "trace_id" => { "type" => "string" }
        }
        mutation ? base.merge(mutation_fields) : base
      end

      def mutation_fields
        {
          "idempotency_key" => { "type" => "string", "minLength" => 1, "maxLength" => 128,
                                 "description" => "Actor-scoped. Omit to let the adapter derive one from " \
                                                  "the request digest, so an identical retry replays the " \
                                                  "prior receipt instead of writing twice." },
          "expected_revision" => { "type" => %w[integer null], "minimum" => 1,
                                   "description" => "Required against an existing record. Null or absent " \
                                                    "means create. A stale value returns kioku.revision_conflict." }
        }
      end

      def correlation
        names = %w[session_id agent_key provider_agent_id parent_agent_key agent_run_id
                   prompt_id tool_use_id worktree_id context_epoch]
        {
          "type" => "object",
          "description" => "Correlation hints only. Unjoinable correlation leaves " \
                           "attribution_state=unresolved; identity is never inferred from timing.",
          "properties" => names.to_h { |name| [name, { "type" => "string" }] },
          "additionalProperties" => false
        }
      end

      def typed_handle(kinds, description)
        {
          "type" => "object",
          "description" => description,
          "properties" => {
            "kind" => { "type" => "string", "enum" => kinds },
            "key" => { "type" => "string", "minLength" => 1 },
            "revision" => { "type" => %w[integer null], "minimum" => 1 }
          },
          "required" => %w[kind key],
          "additionalProperties" => false
        }
      end

      def evidence_ref
        {
          "type" => "object",
          "properties" => {
            "evidence_key" => { "type" => "string" },
            "object_key" => { "type" => "string" },
            "event_key" => { "type" => "string" }
          },
          "minProperties" => 1,
          "maxProperties" => 1,
          "additionalProperties" => false
        }
      end

      def evidence_array(description, min_items: 0)
        {
          "type" => "array",
          "description" => description,
          "minItems" => min_items,
          "items" => {
            "type" => "object",
            "properties" => { "ref" => evidence_ref,
                              "relation" => { "type" => "string", "enum" => RELATIONS } },
            "required" => %w[ref relation],
            "additionalProperties" => false
          }
        }
      end

      def string_array(description)
        { "type" => "array", "description" => description, "items" => { "type" => "string" } }
      end

      def cursor
        { "type" => "string",
          "description" => "Continuation handle from a prior response. Reauthorized on use; " \
                           "an expired or scope-mismatched cursor returns kioku.continuation_expired." }
      end
    end
  end
end
