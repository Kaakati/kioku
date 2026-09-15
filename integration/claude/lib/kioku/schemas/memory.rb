# frozen_string_literal: true

module Kioku
  module Schemas
    # context_remember and context_feedback: the two non-task write tools.
    module Memory
      KINDS = %w[decision constraint correction attempt observation procedure task_checkpoint].freeze

      module_function

      def remember
        {
          "type" => "object",
          "required" => %w[envelope kind destination title body evidence],
          "additionalProperties" => false,
          "properties" => remember_properties,
          "allOf" => [global_requires_applicability]
        }
      end

      def remember_properties
        remember_required_properties.merge(remember_optional_properties)
      end

      def remember_required_properties
        common = Kioku::Schemas::Common
        {
          "envelope" => common.envelope(mutation: true),
          "kind" => { "type" => "string", "enum" => KINDS },
          "destination" => destination,
          "title" => { "type" => "string", "minLength" => 1, "maxLength" => 200 },
          "body" => { "type" => "string", "minLength" => 1, "maxLength" => 16_384 },
          "evidence" => common.evidence_array(
            "At least one eligible evidence link. A write with none is refused with kioku.evidence_required.",
            min_items: 1
          ),
          "applicability" => applicability
        }
      end

      def remember_optional_properties
        {
          "memory_key" => { "type" => "string",
                            "description" => "Append a revision to an existing memory; pairs with " \
                                             "envelope.expected_revision." },
          "lifecycle" => { "type" => "string", "enum" => %w[proposed active],
                           "description" => "Assistant-authored global records default to proposed and do " \
                                            "not become governing user preferences by repetition." },
          "rationale" => { "type" => "string" },
          "tradeoffs" => { "type" => "string" },
          "valid_from" => { "type" => "string", "description" => "RFC3339 valid time, independent of recorded time." },
          "valid_until" => { "type" => "string" },
          "links" => links,
          "derivative" => derivative,
          "override" => override,
          "mandatory" => { "type" => "boolean",
                           "description" => "User authority only. An assistant actor setting it returns " \
                                            "kioku.authority_violation." },
          "origin_project_key" => { "type" => "string", "description" => "Provenance, distinct from ownership." },
          "task_key" => { "type" => "string" },
          "source_anchor" => source_anchor,
          "attempt" => attempt
        }
      end

      def destination
        {
          "type" => "object", "additionalProperties" => false, "required" => ["store_kind"],
          "description" => "An absent or ambiguous project binding returns kioku.project_binding_unresolved. " \
                           "It is never read as permission to write globally.",
          "properties" => {
            "store_kind" => { "type" => "string", "enum" => %w[project global] },
            "project_key" => { "type" => "string", "minLength" => 1 },
            "category" => { "type" => "string", "enum" => Kioku::Envelope::GLOBAL_CATEGORIES }
          },
          "allOf" => [
            { "if" => { "properties" => { "store_kind" => { "const" => "project" } }, "required" => ["store_kind"] },
              "then" => { "required" => ["project_key"] } },
            { "if" => { "properties" => { "store_kind" => { "const" => "global" } }, "required" => ["store_kind"] },
              "then" => { "required" => ["category"] } }
          ]
        }
      end

      def global_requires_applicability
        {
          "if" => {
            "properties" => {
              "destination" => { "properties" => { "store_kind" => { "const" => "global" } },
                                 "required" => ["store_kind"] }
            },
            "required" => ["destination"]
          },
          "then" => { "required" => ["applicability"] }
        }
      end

      def applicability
        common = Kioku::Schemas::Common
        {
          "type" => "object", "additionalProperties" => false, "required" => ["conditions"],
          "description" => "Required for a global record. A global record without applicability conditions " \
                           "is refused.",
          "properties" => {
            "languages" => common.string_array("Applicable languages."),
            "frameworks" => common.string_array("Applicable frameworks."),
            "version_constraints" => common.string_array("Applicable version constraints."),
            "platforms" => common.string_array("Applicable platforms."),
            "conditions" => { "type" => "string", "minLength" => 1 }
          }
        }
      end

      def links
        common = Kioku::Schemas::Common
        { "type" => "object", "additionalProperties" => false,
          "properties" => %w[supersedes derived_from constrains proposed_for rejected_in]
            .to_h { |name| [name, common.string_array("#{name} links.")] } }
      end

      def derivative
        { "type" => "object", "additionalProperties" => false,
          "description" => "The split write: a local application record plus a reusable global record joined " \
                           "by provenance. The global side carries the reusable statement, rationale, " \
                           "applicability and a permitted excerpt only -- never project logs, private paths " \
                           "or source wholesale.",
          "properties" => {
            "publish_global" => { "type" => "boolean" },
            "category" => { "type" => "string", "enum" => Kioku::Envelope::GLOBAL_CATEGORIES },
            "source_revision" => { "type" => "integer", "minimum" => 1 },
            "permitted_excerpt" => { "type" => "string", "maxLength" => 4096 } } }
      end

      def override
        { "type" => "object", "additionalProperties" => false,
          "required" => %w[target_global_memory_key reason],
          "description" => "The project-exception variant. It writes a project-owned override row and leaves " \
                           "the global revision unchanged.",
          "properties" => {
            "target_global_memory_key" => { "type" => "string" },
            "target_revision" => { "type" => "integer", "minimum" => 1 },
            "replacement_body" => { "type" => "string", "maxLength" => 16_384 },
            "exclusion" => { "type" => "boolean" },
            "reason" => { "type" => "string", "minLength" => 1 },
            "authority_basis" => { "type" => "string" },
            "validity_interval" => { "type" => "string" } } }
      end

      def source_anchor
        { "type" => "object", "additionalProperties" => false,
          "properties" => {
            "repository_key" => { "type" => "string" }, "worktree_key" => { "type" => "string" },
            "path" => { "type" => "string" }, "content_hash" => { "type" => "string" },
            "hash_algorithm" => { "type" => "string" }, "commit_oid" => { "type" => %w[string null] },
            "line_start" => { "type" => "integer", "minimum" => 1 },
            "line_end" => { "type" => "integer", "minimum" => 1 },
            "source_view" => { "type" => "string", "enum" => Kioku::Envelope::SOURCE_VIEWS } } }
      end

      def attempt
        common = Kioku::Schemas::Common
        { "type" => "object", "additionalProperties" => false,
          "description" => "Carried on kind=attempt. A rejected attempt keeps why it failed, so an " \
                           "unchanged retry is recognisable as repetition.",
          "properties" => {
            "problem" => { "type" => "string" }, "hypothesis" => { "type" => "string" },
            "actions" => common.string_array("Actions taken."),
            "observations" => common.string_array("What was observed."),
            "verdict" => { "type" => "string" },
            "retry_conditions" => { "type" => "string" } } }
      end

      def feedback
        common = Kioku::Schemas::Common
        { "type" => "object", "required" => %w[envelope target action reason],
          "additionalProperties" => false, "properties" => feedback_properties(common) }
      end

      def feedback_properties(common)
        {
          "envelope" => common.envelope(mutation: true),
          "target" => feedback_target,
          "action" => { "type" => "string", "enum" => %w[dispute useful irrelevant] },
          "reason" => { "type" => "string", "minLength" => 1, "maxLength" => 4096 },
          "evidence" => common.evidence_array("Evidence for the objection."),
          "disposition" => { "type" => "string", "enum" => %w[open resolved withdrawn],
                             "description" => "Only the authorised party may set resolved or withdrawn. " \
                                              "Resolving a dispute does not verify its source." },
          "feedback_key" => { "type" => "string",
                              "description" => "Update an existing feedback record; pairs with " \
                                               "envelope.expected_revision." },
          "scope_note" => { "type" => "string" },
          "proposed_override" => proposed_override,
          "task_key" => { "type" => "string" },
          "context_epoch" => { "type" => "string" }
        }
      end

      def feedback_target
        { "type" => "object", "required" => %w[memory_key revision], "additionalProperties" => false,
          "description" => "An exact revision, not a head pointer: a dispute must name what was disputed. " \
                           "A head-only reference returns kioku.invalid_request.",
          "properties" => {
            "memory_key" => { "type" => "string", "minLength" => 1 },
            "revision" => { "type" => "integer", "minimum" => 1 } } }
      end

      def proposed_override
        { "type" => "object", "additionalProperties" => false,
          "description" => "A routing hint only. context_feedback never writes a project override; the " \
                           "response returns a prepared request the caller submits through " \
                           "context_remember.override.",
          "properties" => {
            "project_key" => { "type" => "string" }, "replacement_body" => { "type" => "string" },
            "exclusion" => { "type" => "boolean" }, "reason" => { "type" => "string" },
            "validity_interval" => { "type" => "string" } } }
      end
    end
  end
end
