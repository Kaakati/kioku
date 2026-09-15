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

      # What that credential is PAIRED TO (plan 6.3: "Pair bridge credentials to
      # an installation and approved roots"). The pairing is deployment
      # configuration of the credential, declared alongside KIOKU_BRIDGE_TOKEN in
      # compose.yml, which is what keeps it transport-derived: nothing a caller
      # sends can change the installation a write is attributed to or the
      # authority it is recorded under (plan 6.1, frozen contract
      # `labels.authority`).
      INSTALLATION_ENV = "KIOKU_BRIDGE_INSTALLATION_KEY"
      ORIGIN_ROLE_ENV = "KIOKU_BRIDGE_ORIGIN_ROLE"
      DEFAULT_ORIGIN_ROLE = "user"

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
          # How identity was established, in the one vocabulary
          # `agents.identity_source` declares (hook|telemetry|transcript|bridge|
          # unresolved). A loopback-bridge caller is `bridge`: nothing but the
          # bridge credential backs the attribution. `transport` named the
          # channel rather than the evidence, and no agents row can carry it, so
          # an event recorded with it could never be reconciled against one.
          identity_source: :bridge,
          # Both derived from the credential's own pairing. Leaving either nil
          # made Actor#authority nil, which writes authority "" into
          # memory_revisions (whose CHECK names the five-value vocabulary) and
          # installation_key NULL into events (NOT NULL): the first HTTP-driven
          # write could not commit at all, and failed as a raw StatementInvalid
          # rather than as a frozen kioku.* refusal.
          origin_role: paired_origin_role,
          installation_key: paired_installation_key,
          # The bridge authenticates a principal, not an agent run. The agent
          # join arrives with captured events, so it stays unresolved here
          # rather than being inferred (invariant 9).
          attribution_state: :unresolved
        )
      end

      # A credential paired to no installation authenticates nothing this core
      # can scope a write to. That is a scope denial, not a malformed request:
      # the caller is who it says it is and still may not write here.
      def paired_installation_key
        key = ENV[INSTALLATION_ENV].to_s
        return key unless key.empty?

        deny_scope!("the bridge credential is not paired to an installation")
      end

      # The five-value origin vocabulary the authority label is derived from
      # (frozen contract, `labels.authority`). A role outside it would produce a
      # label with no defined meaning, so it is refused rather than coerced.
      def paired_origin_role
        role = ENV[ORIGIN_ROLE_ENV].to_s
        role = DEFAULT_ORIGIN_ROLE if role.empty?
        return role if Context::Domain::Actor::AUTHORITY_BY_ORIGIN_ROLE.key?(role.to_sym)

        deny_scope!("the bridge credential names an origin role outside the vocabulary")
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
