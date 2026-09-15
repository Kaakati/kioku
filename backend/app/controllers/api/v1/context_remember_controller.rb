# frozen_string_literal: true

module Api
  module V1
    # POST /api/v1/context_remember — the one mutation in the frozen six-tool
    # surface, and the core end of the capture path of plan 7.1:
    #
    #   context-mcp -> host Unix socket -> context-agent -> loopback bridge ->
    #   HERE -> Context::Services::Memories::Remember -> canonical commit ->
    #   receipt back out.
    #
    # It translates HTTP and nothing else (plan 1.4). The envelope is decoded by
    # the boundary it inherits, the actor comes from the authenticated transport,
    # and every decision about what may be written belongs to the use case. What
    # is left here is the frozen context_remember response shape and the
    # code -> status -> HTTP mapping, which is read from Context::Errors rather
    # than restated.
    class ContextRememberController < BaseController
      kioku_operation :mutation

      # "A save records a conclusion; it never establishes support"
      # [contracts: tools context_remember response_shape].
      CLAIM_SUPPORT = "unassessed"

      # The JSON type each input must carry for the use case to be able to judge
      # it at all. This is NOT the contract's own validation — Context::Contracts
      # owns the resolved tool schema and the closure rule — it is the boundary
      # refusing to hand the use case a value it cannot read, so a malformed body
      # comes back as kioku.invalid_request instead of as an unhandled 500.
      INPUT_TYPES = {
        "kind" => String, "destination" => Hash, "title" => String,
        "body" => String, "evidence" => Array
      }.freeze

      def create
        result = remember.call(actor: current_actor, envelope: envelope, **inputs)
        refuse!(result) unless result.saved?

        render_envelope(status: :success, data: committed(result),
                        coverage: evidence_coverage, receipt: result.receipt.to_h)
      end

      private

      def remember
        Context::Services::Memories::Remember.new(
          object_store: Context::Storage::ObjectStore.new,
          outbox: Context::Storage::Outbox.new
        )
      end

      # E1. The digest covers the body as it ARRIVED, so it is parsed from the raw
      # request rather than read out of Rails' parameters. Parameter parsing drops
      # a key whose value is an explicit null, and an omitted key and a null one
      # digest differently — so digesting the parsed params would disagree with the
      # caller for any request carrying a null (every mutation sends
      # expected_revision, usually null). Rebuilding a body from parsed fields has
      # the same flaw and cannot know which optional keys were sent at all.
      def received_body
        JSON.parse(request.raw_post)
      rescue JSON::ParserError
        nil
      end

      def inputs
        payload = request.request_parameters
        invalid!(INPUT_TYPES.reject { |name, type| payload[name].is_a?(type) }.keys)
        invalid!(["evidence"]) unless payload["evidence"].all?(Hash)

        { kind: payload["kind"], destination: payload["destination"], title: payload["title"],
          body: payload["body"], evidence: payload["evidence"],
          memory_key: payload["memory_key"], applicability: payload["applicability"],
          mandatory: payload["mandatory"] == true, lifecycle: payload["lifecycle"],
          # E1. "The core RECOMPUTES the digest over the RECEIVED body." The body is
          # only faithfully available here: a body rebuilt from parsed fields cannot
          # know which optional keys the caller actually sent, and an omitted key and
          # a null one are different digests. The service falls back to rebuilding
          # one for in-process callers that never had a wire body.
          received_body: received_body }
      end

      # Remember answers a refusal as a Result carrying the frozen wire code
      # rather than by raising, so the boundary turns it back into the error type
      # `rescue_from` already maps. One code -> status -> HTTP table, in
      # Context::Errors, and no second one here.
      def refuse!(result)
        raise Context::Errors.fetch(result.error_code).new(details: result.error_details)
      end

      def invalid!(fields)
        return if fields.empty?

        raise Context::Errors::InvalidRequest.new("the request failed contract validation",
                                                  details: { fields: fields })
      end

      # The frozen data block [contracts: tools context_remember response_shape].
      # `spool` is null here by construction: a spool receipt belongs to a queued
      # answer, and the host agent is the only thing that can produce one.
      def committed(result)
        {
          memory_key: result.memory_key, revision: result.revision,
          head_revision: result.head_revision, store_kind: result.store_kind,
          owner: { project_key: result.project_key, origin_project_key: nil },
          category: result.category, lifecycle: result.lifecycle,
          authority: result.authority, saved: result.saved?,
          evidence_accepted: result.evidence_accepted,
          evidence_rejected: result.evidence_rejected,
          derivative: nil, override: nil,
          # MemoryWriter publishes the lexical projection inside the same
          # transaction as the revision it projects (plan 5.4), so a revision
          # this response reports as committed has one.
          search_document_published: result.saved?,
          outbox_event_id: result.outbox_event_id, spool: nil,
          applicability: result.applicability, claim_support: CLAIM_SUPPORT
        }
      end

      # The declared input set of a save is the evidence it asked to link
      # [contracts: tools context_remember response_shape coverage].
      def evidence_coverage
        refs = request.request_parameters["evidence"].to_a.map { |entry| entry["ref"] }
        declared_set_coverage.merge(declared_input_set: { requested_evidence: refs })
      end
    end
  end
end
