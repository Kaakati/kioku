# frozen_string_literal: true

require_relative "shared"

module Kioku
  module Mcp
    module Schemas
      # The two memory-writing tools [contracts: tools context_remember /
      # context_feedback].
      module Mutation
        module_function

        def remember
          Shared.closed_object(
            %w[envelope kind destination title body evidence],
            "envelope" => Shared.envelope,
            "kind" => Shared.enum(Vocabulary::MEMORY_KINDS),
            "destination" => destination,
            "title" => Shared.string(max: 200),
            "body" => Shared.string(max: 16_384),
            "evidence" => Shared.array(Shared.evidence_link, min: 1, max: 50),
            "applicability" => applicability
          )
        end

        def feedback
          Shared.closed_object(
            %w[envelope target action reason],
            "envelope" => Shared.envelope,
            "target" => target,
            "action" => Shared.enum(Vocabulary::FEEDBACK_ACTIONS),
            "reason" => Shared.string(max: 4096),
            "evidence" => Shared.array(Shared.evidence_link, min: 1, max: 50)
          )
        end

        def destination
          Shared.object(%w[store_kind],
                        "store_kind" => Shared.enum(Vocabulary::STORE_KINDS),
                        "project_key" => Shared.string,
                        "category" => Shared.enum(Vocabulary::GLOBAL_CATEGORIES))
        end

        # "A global record without applicability conditions is refused"
        # [contracts: tools context_remember].
        def applicability
          Shared.object(%w[conditions],
                        "languages" => Shared.string_list,
                        "frameworks" => Shared.string_list,
                        "version_constraints" => Shared.string_list,
                        "platforms" => Shared.string_list,
                        "conditions" => Shared.string)
        end

        # "an exact revision, not a head pointer" [contracts: tools context_feedback].
        def target
          Shared.object(%w[memory_key revision],
                        "memory_key" => Shared.string,
                        "revision" => { "type" => "integer", "minimum" => 1 })
        end
      end
    end
  end
end
