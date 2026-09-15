# frozen_string_literal: true

require_relative "../vocabulary"

module Kioku
  module Mcp
    module Schemas
      # Schema fragments shared by the six published tools.
      #
      # Every tool's top level sets additionalProperties:false, so the published schema
      # is the whole accepted surface: a field the contract does not name — a
      # caller-asserted source check, claim support or execution authorization — has
      # nowhere to land.
      module Shared
        module_function

        def string(min: 1, max: nil)
          schema = { "type" => "string", "minLength" => min }
          schema["maxLength"] = max if max
          schema
        end

        def enum(values)
          { "type" => "string", "enum" => values }
        end

        def array(items, min:, max:)
          { "type" => "array", "items" => items, "minItems" => min, "maxItems" => max }
        end

        def string_list
          { "type" => "array", "items" => { "type" => "string" } }
        end

        def object(required, properties)
          { "type" => "object", "required" => required, "properties" => properties }
        end

        # A tool's top level is closed: the published properties are exactly the accepted
        # ones, and the host refuses anything else with kioku.invalid_request.
        def closed_object(required, properties)
          object(required, properties).merge("additionalProperties" => false)
        end

        def typed_handle
          object(%w[kind key],
                 "kind" => string,
                 "key" => string,
                 "revision" => { "type" => %w[integer null], "minimum" => 1 })
        end

        def fetch_handle
          object(%w[kind key],
                 "kind" => enum(Vocabulary::FETCH_HANDLE_KINDS),
                 "key" => string,
                 "revision" => { "type" => %w[integer null], "minimum" => 1 })
        end

        def evidence_link
          object(%w[ref relation],
                 "ref" => { "type" => "object", "minProperties" => 1 },
                 "relation" => enum(Vocabulary::EVIDENCE_RELATIONS))
        end

        def scope
          object(%w[store],
                 "store" => enum(%w[project global both]),
                 "project_key" => string,
                 "cross_project_keys" => string_list)
        end

        # The common request envelope [contracts: envelope.request_fields]. Mutation-only
        # fields are published here because one envelope serves both directions of the
        # surface; the host rejects a mutation that omits them.
        def envelope
          { "type" => "object",
            "description" => "The common kioku.tool.v1 request envelope.",
            "required" => %w[schema_version request_id deadline_ms scope],
            "properties" => {
              "schema_version" => { "type" => "string", "pattern" => "^kioku\\.tool\\.v1(\\.[0-9]+)?$" },
              "request_id" => { "type" => "string", "minLength" => 36, "maxLength" => 36 },
              "deadline_ms" => { "type" => "integer", "minimum" => 1, "maximum" => 30_000 },
              "scope" => scope,
              "idempotency_key" => string(max: 128),
              "request_digest" => { "type" => "string", "pattern" => "^sha256:[0-9a-f]{64}$" },
              "expected_revision" => { "type" => %w[integer null], "minimum" => 1 }
            } }
        end
      end
    end
  end
end
