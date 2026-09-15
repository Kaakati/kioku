# frozen_string_literal: true

module Kioku
  module Test
    # Api::V1::BaseController is abstract: it carries the envelope contract, the
    # transport-derived actor and the kioku.* -> HTTP mapping, and has no actions
    # of its own. To exercise that boundary we mount probe subclasses on routes
    # that exist only for the duration of a test.
    #
    # Both probes answer POST, because every tool in the frozen surface arrives as
    # a POST regardless of whether it reads or mutates; whether the mutation
    # envelope (idempotency_key, request_digest, expected_revision) is required is
    # declared by the controller through `kioku_operation`, not inferred from the
    # HTTP verb.
    #
    # The subclasses are built lazily inside a method, never at file load: in the
    # red phase Api::V1::BaseController does not exist, and resolving it at load
    # time would abort the runner instead of failing the tests that need it.
    module ApiProbe
      BRIDGE_TOKEN = "test-bridge-token"
      BRIDGE_PRINCIPAL_ID = "kioku.host_bridge"
      LOOPBACK_HOST = "127.0.0.1:7310"
      PROBE_PATH = "/api/v1/probe"
      READ_PROBE_PATH = "/api/v1/read_probe"

      PROBE_ACTION = proc do
        def create
          code = params[:raise_code]
          raise Context::Errors.fetch(code).new(params[:raise_message].presence) if code.present?

          render_envelope(
            status: :success,
            data: {
              "actor" => {
                "principal_id" => current_actor.principal_id,
                "identity_source" => current_actor.identity_source.to_s
              }
            }
          )
        end
      end

      def install_probe_controllers!
        return if Object.const_defined?(:EnvelopeProbeController)

        base = Api::V1::BaseController
        action = PROBE_ACTION

        mutation_probe = Class.new(base) do
          kioku_operation :mutation
          class_eval(&action)
        end
        read_probe = Class.new(base) do
          kioku_operation :read
          class_eval(&action)
        end

        Object.const_set(:ReadProbeController, read_probe)
        Object.const_set(:EnvelopeProbeController, mutation_probe)
      end

      def probe_headers(token: BRIDGE_TOKEN, host: LOOPBACK_HOST)
        headers = { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => host }
        headers["HTTP_AUTHORIZATION"] = "Bearer #{token}" unless token.nil?
        headers
      end

      # The transport options are keyword-shaped at the call site but cannot be
      # declared as keyword parameters: Ruby 3 reads a trailing braceless hash
      # as keywords, so `post_probe("envelope" => ...)` — the form most cases
      # use — would raise ArgumentError before a request was ever made. The
      # options are collected instead, and whatever is left over is the body.
      TRANSPORT_OPTIONS = %i[path token host headers].freeze

      def post_probe(body = {}, **options)
        transport = options.slice(*TRANSPORT_OPTIONS)
        post transport.fetch(:path, PROBE_PATH),
             params: body.merge(options.except(*TRANSPORT_OPTIONS)).to_json,
             headers: probe_headers(token: transport.fetch(:token, BRIDGE_TOKEN),
                                    host: transport.fetch(:host, LOOPBACK_HOST))
                        .merge(transport.fetch(:headers, {}))
        probe_body
      end

      def post_read_probe(body = {}, **options)
        post_probe(body, path: READ_PROBE_PATH, **options)
      end

      # Sends a probe request carrying a valid envelope plus an instruction to
      # raise one frozen wire error, and returns the parsed response body.
      def probe_raising(wire_code, message: nil)
        body = { "envelope" => wire_envelope, "raise_code" => wire_code }
        body["raise_message"] = message if message
        post_probe(body)
      end

      def probe_body
        JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end
    end

    # Installs the probe routes for a whole test case.
    #
    # `with_routing` restores the previous integration session on the way out, so
    # the temporary route set has to live for the entire test rather than only
    # around the request: wrapping a single call would leave `response` pointing
    # at the restored session by the time the assertions run.
    module ProbeRoutes
      def self.included(base)
        base.with_routing do |set|
          set.draw do
            post Kioku::Test::ApiProbe::PROBE_PATH, to: "envelope_probe#create"
            post Kioku::Test::ApiProbe::READ_PROBE_PATH, to: "read_probe#create"
          end
        end

        base.setup { install_probe_controllers! }
      end
    end
  end
end
