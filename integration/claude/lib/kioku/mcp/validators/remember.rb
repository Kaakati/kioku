# frozen_string_literal: true

require_relative "../rules"
require_relative "../vocabulary"
require_relative "../../envelope"

module Kioku
  module Mcp
    module Validators
      # [contracts: tools context_remember]. A save records a conclusion; it never
      # establishes support, so claim_support, authority and any normalized check result
      # are absent from the accepted surface and a caller that supplies one is refused.
      class Remember
        PERMITTED = %w[envelope kind destination title body evidence applicability].freeze

        MAX_TITLE = 200
        MAX_BODY = 16_384
        MAX_CONDITIONS = 4096

        def call(arguments:)
          Rules.only(arguments, PERMITTED)
          envelope = Kioku::Envelope.parse_request(arguments["envelope"], mutation: true)
          Rules.enum(arguments, "kind", Vocabulary::MEMORY_KINDS)
          validate_destination(arguments)
          Rules.text(arguments, "title", max: MAX_TITLE)
          Rules.text(arguments, "body", max: MAX_BODY)
          validate_evidence(arguments)
          envelope
        end

        private

        def validate_destination(arguments)
          destination = Rules.object(arguments, "destination")
          store_kind = Rules.enum(destination, "store_kind", Vocabulary::STORE_KINDS)

          if store_kind == "global"
            validate_global(arguments, destination)
          else
            validate_project(destination)
          end
        end

        # "An absent or ambiguous project binding returns kioku.project_binding_unresolved;
        # it is never read as permission to write globally"
        # [contracts: tools context_remember].
        def validate_project(destination)
          key = destination["project_key"]
          return if key.is_a?(String) && !key.strip.empty?

          raise Kioku::Error.new("kioku.project_binding_unresolved",
                                 message: "a project memory names no bound project",
                                 details: { "setup_required" => true })
        end

        # "A global record without applicability conditions is refused"
        # [contracts: tools context_remember].
        def validate_global(arguments, destination)
          Rules.enum(destination, "category", Vocabulary::GLOBAL_CATEGORIES)
          applicability = Rules.object(arguments, "applicability")
          Rules.text(applicability, "conditions", max: MAX_CONDITIONS)
        end

        # "the core ... rejects the write with kioku.evidence_required if none is eligible"
        # [contracts: tools context_remember; errors kioku.evidence_required].
        def validate_evidence(arguments)
          entries = arguments["evidence"]
          Rules.invalid!("evidence must be an array of evidence links") unless entries.is_a?(Array)
          evidence_required! if entries.empty?
          Rules.invalid!("evidence carries more than 50 links") if entries.size > 50

          entries.each_with_index { |entry, index| validate_link(entry, index) }
        end

        def validate_link(entry, index)
          Rules.invalid!("evidence[#{index}] must be an object") unless entry.is_a?(Hash)
          ref = entry["ref"]
          Rules.invalid!("evidence[#{index}].ref must name a reference") unless ref.is_a?(Hash) && ref.any?
          Rules.enum(entry, "relation", Vocabulary::EVIDENCE_RELATIONS)
        end

        def evidence_required!
          raise Kioku::Error.new("kioku.evidence_required",
                                 message: "an explicit memory write carries at least one evidence link")
        end
      end
    end
  end
end
