# frozen_string_literal: true

module Api
  module V1
    # The HTTP boundary shared by every /api/v1 endpoint.
    #
    # It owns only what is genuinely HTTP: proving the request arrived over the
    # authenticated loopback transport, bounding the payload, and mapping the
    # frozen kioku.* wire names onto HTTP statuses. Envelope validation, the
    # error catalogue and the response envelope live in Context::Contracts and
    # Context::Serialization so that the MCP adapter and this controller cannot
    # drift apart; nothing here re-implements them.
    #
    # Endpoints under this namespace are POSTed: the envelope is a structured
    # object (nested scope, correlation) that does not survive a query string.
    class BaseController < ActionController::API
      MAX_REQUEST_BYTES = 1_048_576

      # The api publishes on 127.0.0.1 only; the ui container reaches it as
      # `api` on the internal Compose network. Nothing else is a legitimate
      # origin for a core mutation (Plan 6.3).
      LOOPBACK_HOSTS = ["127.0.0.1", "localhost", "::1", "[::1]", "api"].freeze

      # The body's status and error.code are authoritative; the HTTP status is a
      # refinement for proxies and generic clients. Errors whose contract status
      # is nil are transport-level failures and carry no envelope status.
      HTTP_STATUS = {
        "kioku.revision_conflict" => :conflict,
        "kioku.idempotency_conflict" => :conflict,
        "kioku.precondition_failed" => :precondition_failed,
        "kioku.authority_violation" => :conflict,
        "kioku.evidence_required" => :conflict,
        "kioku.continuation_expired" => :conflict,
        "kioku.scope_denied" => :forbidden,
        "kioku.project_binding_unresolved" => :forbidden,
        "kioku.source_unavailable" => :service_unavailable,
        "kioku.evidence_unavailable" => :gone,
        "kioku.quota_exhausted" => :too_many_requests,
        "kioku.deadline_exceeded" => :gateway_timeout,
        "kioku.invalid_request" => :bad_request,
        "kioku.handle_unresolved" => :not_found,
        "kioku.unsupported_operation" => :bad_request,
        "kioku.unsupported_schema_version" => :bad_request,
        "kioku.internal_error" => :internal_server_error
      }.freeze

      # Concrete controllers declare which tool contract they decode and whether
      # the operation mutates. Mutation cannot be inferred from the HTTP verb
      # here, because every endpoint POSTs.
      class_attribute :envelope_tool, instance_writer: false, default: nil
      class_attribute :envelope_op, instance_writer: false, default: nil
      class_attribute :envelope_mutation, instance_writer: false, default: false

      before_action :start_request_clock
      before_action :require_loopback_transport
      before_action :require_bounded_payload
      before_action :authenticate_actor
      before_action :parse_envelope

      rescue_from Context::Errors::Error, with: :render_kioku_error
      rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_unparsable_body

      private

      attr_reader :actor, :envelope, :started_at

      # One clock per request: the deadline is relative, and every elapsed_ms in
      # the response is measured from here rather than from whenever a service
      # happened to start.
      def start_request_clock
        @started_at = Time.now.utc
      end

      def require_loopback_transport
        deny_transport("host") unless loopback?(request.host)

        origin = request.headers["Origin"]
        return if origin.blank?

        uri = URI.parse(origin)
        deny_transport("origin") unless %w[http https].include?(uri.scheme) && loopback?(uri.host)
      rescue URI::InvalidURIError
        deny_transport("origin")
      end

      def loopback?(host)
        LOOPBACK_HOSTS.include?(host.to_s.downcase)
      end

      # The rejected value is never echoed: it is attacker-controlled text and
      # error messages stay content-redacted.
      def deny_transport(field)
        raise Context::Errors::ScopeDenied.new("Request did not arrive over the loopback transport",
                                               details: { field: field })
      end

      def require_bounded_payload
        observed = request.content_length.to_i
        return if observed <= MAX_REQUEST_BYTES

        render_kioku_error(
          Context::Errors::QuotaExhausted.new("Request body exceeds the accepted bound",
                                              details: { quota_kind: "request_bytes",
                                                         limit: MAX_REQUEST_BYTES, observed: observed }),
          http_status: :payload_too_large
        )
      end

      # Actor identity comes from the authenticated transport, never from request
      # text. A missing and an incorrect token are answered identically, so the
      # endpoint does not confirm that a credential exists.
      def authenticate_actor
        expected = ENV["KIOKU_BRIDGE_TOKEN"].to_s
        presented = request.authorization.to_s.delete_prefix("Bearer ")

        unless expected.present? && ActiveSupport::SecurityUtils.secure_compare(expected, presented)
          return render_kioku_error(
            Context::Errors::ScopeDenied.new("The transport is not an authenticated Kioku principal",
                                             details: { reason: "unauthenticated_transport" }),
            http_status: :unauthorized
          )
        end

        @actor = build_actor(resolve_installation)
      end

      # origin_role is `tool` and attribution stays unresolved: a bridge
      # credential identifies the installation, not the person or agent behind a
      # turn. Resolving that is the core's correlation join, never a header.
      def build_actor(installation)
        Context::Contracts::Actor.from_transport(
          principal_id: "principal:bridge:#{installation.installation_key}",
          origin_role: "tool",
          transport: "mcp_bridge",
          installation_id: installation.id,
          identity_source: "bridge"
        )
      end

      # The token authenticates the installation, and a deployment registers
      # exactly one. Zero or several is an unresolved binding, not a reason to
      # pick one: the caller is told setup is incomplete rather than being
      # silently attached to an installation it never named.
      def resolve_installation
        candidates = Installation.order(:created_at).limit(2).to_a
        return candidates.first if candidates.one?

        raise Context::Errors::ProjectBindingUnresolved.new(
          "The bridge credential does not resolve to exactly one installation",
          details: { setup_required: true, installations_found: candidates.size }
        )
      end

      def parse_envelope
        @envelope = Context::Contracts::Envelope.parse(
          params.to_unsafe_h["envelope"],
          tool: envelope_tool,
          op: envelope_op,
          mutation: envelope_mutation,
          started_at: started_at
        )
      end

      # Errors raised before the envelope parses still need a deadline to report
      # limits.deadline_at against; the per-tool policy default supplies one.
      def deadline
        @deadline ||= envelope&.deadline ||
                      Context::Contracts::Deadline.for(tool: envelope_tool, op: envelope_op,
                                                       requested_ms: nil, started_at: started_at || Time.now.utc)
      end

      def render_kioku_error(error, http_status: nil)
        result = Context::Serialization::Result.from_error(
          error: error, request_id: envelope&.request_id, deadline: deadline
        )
        render json: result.to_wire, status: http_status || HTTP_STATUS.fetch(error.wire_name, :internal_server_error)
      end

      def render_unparsable_body(_error)
        render_kioku_error(
          Context::Errors::InvalidRequest.new("Request body is not valid JSON",
                                              details: { field: "body", reason: "unparsable" })
        )
      end
    end
  end
end
