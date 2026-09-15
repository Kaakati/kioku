# frozen_string_literal: true

require "json"

module Kioku
  module TestSupport
    # Reads the host deploy unit's committed mirror of the shared kioku.tool.v1
    # artifact (contracts/v1 -> lib/kioku/contracts/v1).
    #
    # Nothing in this file restates a value the artifact already carries. Every
    # enum, bound, status, error name and conformance case comes out of the JSON,
    # so a test cannot agree with a stale Ruby transcription: if the Ruby drifts
    # from the artifact, the test that reads the artifact is the one that fails.
    module ContractFixtures
      MIRROR = File.join(KIOKU_PACKAGE_ROOT, "lib", "kioku", "contracts", "v1")
      REPO_ROOT = File.expand_path(File.join(KIOKU_PACKAGE_ROOT, "..", ".."))
      SOURCE = File.join(REPO_ROOT, "contracts", "v1")
      BACKEND_MIRROR = File.join(REPO_ROOT, "backend", "lib", "context", "contracts", "schemas", "v1")

      module_function

      def artifact(relative_path)
        JSON.parse(File.read(File.join(MIRROR, relative_path)))
      end

      def mirror_files
        Dir.glob(File.join(MIRROR, "**", "*.json")).map { |path| path.sub("#{MIRROR}/", "") }.sort
      end

      def source_files
        Dir.glob(File.join(SOURCE, "**", "*.json")).map { |path| path.sub("#{SOURCE}/", "") }.sort
      end

      def backend_mirror_files
        Dir.glob(File.join(BACKEND_MIRROR, "**", "*.json"))
           .map { |path| path.sub("#{BACKEND_MIRROR}/", "") }.sort
      end

      # --- the tables both sides must agree with ------------------------------

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

      def tools
        resolved_tools.keys
      end

      # --- conformance cases ---------------------------------------------------

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
        base = request_cases.fetch("base_envelopes").fetch(kase.fetch("envelope"))
        apply_patch(base, kase["envelope_patch"], kase["envelope_delete"])
      end

      def response_wire_for(kase)
        apply_patch(response_cases.fetch("wire_base"), kase["wire_patch"], kase["wire_delete"])
      end

      # A tool case is one complete set of MCP tool arguments: the named base body
      # patched, with its envelope patched independently.
      def tool_arguments_for(kase)
        base = tool_cases.fetch("base_bodies").fetch(kase.fetch("base"))
        envelope = apply_patch(tool_cases.fetch("base_envelopes").fetch(base.fetch("envelope")),
                               kase["envelope_patch"], kase["envelope_delete"])
        body = apply_patch(base.fetch("body"), kase["body_patch"], kase["body_delete"])
        [base.fetch("tool"), body.merge("envelope" => envelope)]
      end

      # The canonical body both deploy units digest in the request-digest tests.
      # It is the artifact's own remember fixture, so neither side can pin a body
      # the other does not have. It arrives carrying the placeholder
      # envelope.request_digest the fixture declares, which a recomputation must
      # ignore: a digest cannot be one of its own inputs, or the asserted value
      # could never be compared against the computed one.
      def golden_digest_body
        base = tool_cases.fetch("base_bodies").fetch("remember_project")
        base.fetch("body").merge("envelope" => tool_cases.fetch("base_envelopes").fetch("mutation"))
      end

      # The single value both deploy units must produce for `golden_digest_body`.
      # Two independent implementations of one canonicalization rule are exactly
      # the drift this artifact exists to stop, and a property test alone would
      # not catch two rules that are each internally consistent.
      GOLDEN_REQUEST_DIGEST = "sha256:ecd8db48c21a57428d46c56947d747d172d2f02a69f9961e2a80a251ac211a15"

      # The digest a well-behaved caller would assert for a body, used by the tool
      # conformance harness so that cases about tool arguments are not all refused
      # by the digest check the artifact's placeholder digest would trip.
      def with_asserted_digest(arguments, digest)
        envelope = arguments.fetch("envelope").merge("request_digest" => digest)
        arguments.merge("envelope" => envelope)
      end
    end
  end
end
