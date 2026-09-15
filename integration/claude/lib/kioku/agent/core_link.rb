# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "../errors"

module Kioku
  module Agent
    # The AGENT's end of the authenticated loopback bridge.
    #
    # "The agent initiates a persistent authenticated control connection to the
    # core; the host does not expose another inbound service" [plan §3.1]. The
    # direction matters: nothing in the core can call into the host, and the host
    # opens no port. The session is held open and reused, which is what
    # "persistent" means here.
    #
    # It invents no answer. When the core does not respond, or responds with
    # something that is not a response envelope, the caller is told the source is
    # unavailable — never that the write was saved.
    class CoreLink
      DEFAULT_BASE_URL = "http://127.0.0.1:7310"
      MIN_TIMEOUT_SECONDS = 0.5
      MAX_TIMEOUT_SECONDS = 30.0
      KEEP_ALIVE_SECONDS = 30

      TRANSPORT_ERRORS = [SystemCallError, IOError, EOFError, SocketError,
                          Timeout::Error, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError].freeze

      def initialize(base_url: DEFAULT_BASE_URL, token: nil, logger: nil)
        @base = URI.parse(base_url.to_s.empty? ? DEFAULT_BASE_URL : base_url)
        @token = token.to_s
        @logger = logger
        @lock = Mutex.new
      end

      def post(path:, payload:, deadline_ms:)
        body = JSON.generate(payload)
        decode(@lock.synchronize { exchange(path, body, budget(deadline_ms)) })
      end

      private

      # One retry, because a persistent connection the core closed while idle
      # fails on its next use and that is not evidence the core is down. The
      # retry is safe for exactly the reason the contract exists: the call
      # carries an actor-scoped idempotency key and the core answers a repeat
      # from its receipt rather than committing twice.
      def exchange(path, body, timeout)
        attempt(path, body, timeout)
      rescue *TRANSPORT_ERRORS
        reset
        retried(path, body, timeout)
      end

      def retried(path, body, timeout)
        attempt(path, body, timeout)
      rescue *TRANSPORT_ERRORS => error
        reset
        unavailable!("the core did not answer over the loopback bridge (#{error.class})")
      end

      def attempt(path, body, timeout)
        session(timeout).request(post_request(path, body))
      end

      def session(timeout)
        http = (@http ||= build_session)
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout
        http.start unless http.started?
        http
      end

      def build_session
        http = Net::HTTP.new(@base.host, @base.port)
        http.use_ssl = @base.scheme == "https"
        http.keep_alive_timeout = KEEP_ALIVE_SECONDS
        http
      end

      def reset
        @http&.finish if @http&.started?
      rescue *TRANSPORT_ERRORS
        nil
      ensure
        @http = nil
      end

      def post_request(path, body)
        request = Net::HTTP::Post.new(path)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request["Authorization"] = "Bearer #{@token}"
        request.body = body
        request
      end

      # The core answered, so its envelope is what the caller gets — a refusal
      # included. Only an answer that is not an envelope at all leaves the call
      # unacknowledged, because then the host has nothing honest to relay and a
      # capture that is still on the spool must be reported as queued.
      def decode(response)
        payload = JSON.parse(response.body.to_s)
        return payload if payload.is_a?(Hash)

        unavailable!("the core answered #{response.code} with a body that is not an envelope")
      rescue JSON::ParserError
        unavailable!("the core answered #{response.code} with a body that is not JSON")
      end

      # The caller's own budget bounds the round trip, so a slow core spends the
      # caller's deadline rather than an unbounded wait.
      def budget(deadline_ms)
        seconds = deadline_ms.to_i / 1000.0
        seconds.clamp(MIN_TIMEOUT_SECONDS, MAX_TIMEOUT_SECONDS)
      end

      def unavailable!(detail)
        @logger&.warn(detail)
        raise Kioku::Error.new("kioku.source_unavailable", message: detail,
                                                           details: { "host_link_state" => "disconnected" })
      end
    end
  end
end
