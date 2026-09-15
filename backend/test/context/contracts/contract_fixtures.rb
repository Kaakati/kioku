# frozen_string_literal: true

require "json"

module Kioku
  module Test
    # Reads the core deploy unit's committed mirror of the shared kioku.tool.v1
    # artifact (contracts/v1 -> lib/context/contracts/schemas/v1).
    #
    # The backend suite runs inside the container with only ./backend mounted and
    # cannot see contracts/v1. Its protection against a stale mirror is that its
    # fixtures come from the mirror: a stale mirror makes these cases disagree with
    # the host suite's, and the host's cross-tree case names the offending file.
    #
    # Nothing here restates a value the artifact carries. If a Ruby constant in
    # lib/context drifts from the artifact, the test reading the artifact fails.
    module ContractFixtures
      MIRROR = Rails.root.join("lib/context/contracts/schemas/v1")

      module_function

      def artifact(relative_path)
        JSON.parse(File.read(MIRROR.join(relative_path)))
      end

      def errors
        artifact("errors.json").fetch("errors")
      end

      def response_statuses
        artifact("common.schema.json").dig("$defs", "response_status", "enum")
      end

      def contract
        artifact("contract.json")
      end

      def resolved_tools
        artifact("conformance/resolved_tools.json")
      end

      def request_cases
        artifact("conformance/envelope_request_cases.json")
      end

      def response_cases
        artifact("conformance/envelope_response_cases.json")
      end

      def tool_cases
        artifact("conformance/tool_input_cases.json")
      end

      # "merged over the named base one level deep; a nested object replaces the
      # base's value for that key outright, and an explicit null sets that key to
      # JSON null. <thing>_delete removes the named keys entirely, which is how an
      # ABSENT field is distinguished from a null one."
      def apply_patch(base, patch, deletions)
        merged = base.merge(patch || {})
        Array(deletions).each { |key| merged.delete(key) }
        merged
      end

      def request_envelope_for(kase)
        apply_patch(request_cases.fetch("base_envelopes").fetch(kase.fetch("envelope")),
                    kase["envelope_patch"], kase["envelope_delete"])
      end

      def response_wire_for(kase)
        apply_patch(response_cases.fetch("wire_base"), kase["wire_patch"], kase["wire_delete"])
      end

      def tool_arguments_for(kase)
        base = tool_cases.fetch("base_bodies").fetch(kase.fetch("base"))
        envelope = apply_patch(tool_cases.fetch("base_envelopes").fetch(base.fetch("envelope")),
                               kase["envelope_patch"], kase["envelope_delete"])
        body = apply_patch(base.fetch("body"), kase["body_patch"], kase["body_delete"])
        [base.fetch("tool"), body.merge("envelope" => envelope)]
      end

      # The canonical body both deploy units digest. It carries the fixture's
      # placeholder envelope.request_digest, which a recomputation must ignore: a
      # digest cannot be one of its own inputs, or the asserted value could never
      # be compared against the computed one.
      def golden_digest_body
        base = tool_cases.fetch("base_bodies").fetch("remember_project")
        base.fetch("body").merge("envelope" => tool_cases.fetch("base_envelopes").fetch("mutation"))
      end

      # The single value both deploy units must produce for `golden_digest_body`.
      # The identical literal is pinned in the host suite
      # (integration/claude/test/kioku/contract_fixtures.rb). Two implementations of
      # one canonicalization rule are exactly the drift this artifact exists to
      # stop, and property tests alone would not catch two rules that are each
      # internally consistent.
      GOLDEN_REQUEST_DIGEST = "sha256:ecd8db48c21a57428d46c56947d747d172d2f02a69f9961e2a80a251ac211a15"
    end

    # Turns one conformance case's declared expectation into assertions against the
    # core's real decoder or serializer. The expectation vocabulary is the
    # artifact's; nothing here decides what any of it should be.
    module ContractAssertions
      def assert_outcome(expect, context)
        outcome = begin
          [:accepted, yield]
        rescue Context::Errors::Error => e
          [:refused, e]
        end

        state, value = outcome
        if expect.fetch("outcome") == "accepted"
          assert_equal :accepted, state,
                       "#{context}: the contract declares this accepted, but it was refused with " \
                       "#{state == :refused ? "#{value.wire_code}: #{value.message}" : ''}"
        else
          assert_equal :refused, state,
                       "#{context}: the contract declares this refused with #{expect.fetch('code')}"
          assert_equal expect.fetch("code"), value.wire_code, "#{context}: #{value.message}"
        end
        value
      end

      def assert_refusal_detail(expect, error, context)
        (Array(expect["rejected_fields"]) + Array(expect["field"])).each do |field|
          assert_names_field(error, field, context)
        end
        (expect["details"] || {}).each do |key, value|
          assert_equal value, detail(error, key),
                       "#{context}: the refusal's details.#{key} does not carry the declared reason"
        end
      end

      def assert_names_field(error, field, context)
        name = field.to_s.split(%r{[/.]}).reject(&:empty?).last
        candidates = Array(detail(error, "fields")) + Array(detail(error, "rejected_fields"))
        named = candidates.map(&:to_s).include?(field) || error.message.include?(name)

        assert named, "#{context}: the refusal must name #{field.inspect}, but it reported " \
                      "#{error.message.inspect} with details #{error.details.inspect}"
      end

      def detail(error, key)
        details = error.details || {}
        details[key.to_sym] || details[key.to_s]
      end

      def each_case(cases, side:)
        failures = []
        cases.each do |kase|
          next unless Array(kase["sides"]).empty? || Array(kase["sides"]).include?(side)

          begin
            yield kase
          rescue Minitest::Assertion => e
            failures << "#{kase.fetch('id')}: #{e.message}"
          end
        end
        assert_empty failures, "#{failures.size} conformance case(s) failed:\n- #{failures.join("\n- ")}"
      end
    end
  end
end
