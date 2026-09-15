# frozen_string_literal: true

require "ipaddr"

module Api
  module V1
    # The envelope boundary every tool route inherits.
    #
    # It translates HTTP and nothing else (plan 1.4): it establishes the trusted
    # actor from the transport, decodes the common envelope, renders the shared
    # response and maps a frozen kioku.* error onto an HTTP status. Use cases
    # live in Context::Services.
    #
    # Every tool arrives as a POST whether it reads or mutates, so a subclass
    # declares which it is with `kioku_operation`; the mutation envelope fields
    # are required only for the latter rather than inferred from the verb.
    class BaseController < ActionController::API
      # Plan 6.1: actor identity comes from authenticated transport, never from
      # request text, and a caller-supplied identity field is rejected outright.
      # Correlation hints are a separate, permitted envelope field.
      CORE_DERIVED_FIELDS = %w[
        actor actor_principal_id principal_id authority origin_role
        identity_source attribution_state
      ].freeze

      # Only api (7310) and ui (7311) publish host ports, and only on 127.0.0.1
      # (plan 3/3.1), so a request claiming any other host or origin did not
      # arrive over the trusted loopback bridge.
      LOOPBACK_NAMES = %w[localhost ::1].freeze

      # The installation-scoped principal the bridge credential authenticates
      # (plan 6.3: bridge credentials are paired to an installation).
      BRIDGE_PRINCIPAL_ID = "kioku.host_bridge"

      class_attribute :kioku_operation_kind, instance_writer: false, default: :read

      def self.kioku_operation(kind)
        unless Context::Contracts::EnvelopeDecoder::OPERATIONS.include?(kind)
          raise ArgumentError, "unknown kioku operation #{kind.inspect}"
        end

        self.kioku_operation_kind = kind
      end

      rescue_from Context::Errors::Error, with: :render_context_error

      before_action :start_request_clock
      before_action :enforce_loopback_origin!
      before_action :authenticate_bridge!
      before_action :reject_core_derived_fields!
      before_action :decode_envelope!

      private

      attr_reader :envelope

      def current_actor
        @current_actor ||= Context::Domain::Actor.new(
          principal_id: BRIDGE_PRINCIPAL_ID,
          identity_source: :transport,
          # The bridge authenticates a principal, not an agent run. The agent
          # join arrives with captured events, so it stays unresolved here
          # rather than being inferred (invariant 9).
          attribution_state: :unresolved
        )
      end

      def render_envelope(status:, data: nil, error: nil, coverage: nil,
                          continuation: nil, receipt: nil, warnings: [],
                          http_status: :ok)
        render json: Context::Serialization::Response.call(
          request_id: envelope&.request_id,
          status: status,
          data: data,
          error: error,
          coverage: coverage || declared_set_coverage,
          generation_vector: observed_generation_vector,
          continuation: continuation,
          receipt: receipt,
          limits: limits,
          warnings: warnings,
          server_time: now.iso8601(3)
        ), status: http_status
      end

      def render_context_error(error)
        render_envelope(status: error.wire_status, error: error.to_wire,
                        http_status: error.http_status)
      end

      # --- transport -------------------------------------------------------

      def start_request_clock
        started_at
      end

      def enforce_loopback_origin!
        return if loopback_host?(request.host) && loopback_origin?

        deny_scope!("the request did not arrive over the loopback bridge")
      end

      def loopback_origin?
        origin = request.headers["Origin"]
        return true if origin.blank?

        loopback_host?(URI.parse(origin).host)
      rescue URI::InvalidURIError
        false
      end

      def loopback_host?(host)
        name = host.to_s.downcase.delete_prefix("[").delete_suffix("]")
        return false if name.empty?
        return true if LOOPBACK_NAMES.include?(name)

        IPAddr.new(name).loopback?
      rescue IPAddr::InvalidAddressError
        # A name that merely starts with a loopback literal, such as
        # 127.0.0.1.evil.example, is a rebinding attempt, not loopback.
        false
      end

      # The contract freezes no separate authentication code, so an unrecognised
      # credential is denied with kioku.scope_denied and answered 401. The denial
      # discloses nothing about what exists.
      def authenticate_bridge!
        return if bridge_credential_accepted?

        deny_scope!("the bridge credential was not accepted", http_status: :unauthorized)
      end

      def bridge_credential_accepted?
        expected = ENV["KIOKU_BRIDGE_TOKEN"].to_s
        return false if expected.empty?

        ActiveSupport::SecurityUtils.secure_compare(presented_credential, expected)
      end

      def presented_credential
        request.headers["Authorization"].to_s.delete_prefix("Bearer ")
      end

      def deny_scope!(message, http_status: nil)
        raise Context::Errors::ScopeDenied.new(message, http_status: http_status)
      end

      # --- request ---------------------------------------------------------

      def reject_core_derived_fields!
        supplied = CORE_DERIVED_FIELDS & request_body_keys
        return if supplied.empty?

        raise Context::Errors::InvalidRequest.new(
          "actor identity and authority are derived from the authenticated transport",
          details: { rejected_fields: supplied }
        )
      end

      def request_body_keys
        request.request_parameters.keys.map(&:to_s)
      rescue ActionDispatch::Http::Parameters::ParseError
        []
      end

      def decode_envelope!
        @envelope = Context::Contracts::EnvelopeDecoder
                    .new(operation: self.class.kioku_operation_kind)
                    .call(request.request_parameters["envelope"])
      end

      # --- response --------------------------------------------------------

      def limits
        {
          deadline_at: envelope&.deadline_at(started_at)&.iso8601(3),
          elapsed_ms: ((now - started_at) * 1000).round,
          candidate_limit: nil,
          returned: nil,
          truncated: false
        }
      end

      def declared_set_coverage
        {
          state: :complete_for_declared_set,
          declared_input_set: {},
          counts: { considered: 0, returned: 0, truncated_at: nil },
          gaps: [],
          completeness_label: "known_within_indexed_coverage"
        }
      end

      # Plan 6.1 requires the observed generation vector on a response whose
      # scope resolved; the contract says an unsupported schema version is
      # "returned before any scope resolution; no generation vector is
      # available", so it is null until the envelope decodes.
      #
      # No generation counter and no host control connection exist yet, so every
      # counter reports its initial value and the host link is reported as
      # disconnected rather than assumed connected (invariant 6).
      def observed_generation_vector
        return nil if envelope.nil?

        {
          canonical_generation: 0, policy_generation: 0, global_generation: 0,
          index_generation: 0, source_epoch: 0, deletion_epoch: 0,
          host_link_state: :disconnected, observed_at: now.iso8601(3)
        }
      end

      def started_at
        @started_at ||= Time.now.utc
      end

      def now
        Time.now.utc
      end
    end
  end
end
