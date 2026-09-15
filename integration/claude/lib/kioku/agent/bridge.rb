# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Kioku
  module Agent
    # The authenticated loopback connection to the Rails core for ordinary
    # request/response work: tool calls, spool replay and health.
    #
    # Only the agent holds it. contextctl and context-mcp reach the core through
    # the agent's Unix socket, so the bridge credential never leaves this
    # process and the host exposes no inbound service of its own.
    class Bridge
      TOOL_PATH = "/api/v1/tools"
      REPLAY_PATH = "/api/v1/host/spool/replay"
      CAPSULE_PATH = "/api/v1/host/capsule"
      HEALTH_PATH = "/up"

      def initialize(api_url:, token:, logger:, installation_id: nil)
        @uri = URI.parse(api_url)
        @token = token
        @logger = logger
        @installation_id = installation_id
      end

      attr_reader :uri

      def tool_call(tool:, envelope:, arguments:, deadline_ms:)
        post("#{TOOL_PATH}/#{tool}", { "envelope" => envelope, "arguments" => arguments }, deadline_ms)
      end

      def replay(entries:)
        post(REPLAY_PATH, { "entries" => entries }, 15_000)
      end

      # The bounded context capsule for an eligible hook event. The core owns
      # what belongs in it; the host only supplies the binding and correlation.
      def capsule(payload:, deadline_ms:)
        post(CAPSULE_PATH, payload, deadline_ms)
      end

      # Readiness as the host can observe it. The core's /up confirms database
      # connectivity and schema presence; whatever else it reports is passed
      # through unchanged rather than reinterpreted here.
      def health(deadline_ms: 2_000)
        body = get(HEALTH_PATH, deadline_ms)
        { "reachable" => true, "body" => body }
      rescue Kioku::TransportUnavailable => e
        { "reachable" => false, "detail" => e.message }
      rescue Kioku::Error => e
        { "reachable" => true, "error" => e.to_error_object }
      end

      private

      def post(path, body, deadline_ms)
        request = Net::HTTP::Post.new(path, headers)
        request.body = JSON.generate(body)
        perform(request, deadline_ms)
      end

      def get(path, deadline_ms)
        perform(Net::HTTP::Get.new(path, headers), deadline_ms)
      end

      def headers
        {
          "Content-Type" => "application/json",
          "Accept" => "application/json",
          "Authorization" => "Bearer #{@token}",
          "Origin" => "#{@uri.scheme}://#{@uri.host}:#{@uri.port}",
          "X-Kioku-Protocol" => Kioku::FRAME_PROTOCOL,
          "X-Kioku-Installation" => @installation_id.to_s,
          "User-Agent" => "kioku-context-agent/#{Kioku::VERSION}"
        }.compact
      end

      def perform(request, deadline_ms)
        seconds = deadline_ms / 1000.0
        response = http(seconds).request(request)
        decode(response)
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Kioku::Error.new("kioku.deadline_exceeded", "the core did not answer within the deadline")
      rescue SystemCallError, SocketError, IOError, EOFError => e
        raise Kioku::TransportUnavailable.new("kioku-core", e.class.name)
      end

      def http(seconds)
        client = Net::HTTP.new(@uri.host, @uri.port)
        client.use_ssl = @uri.scheme == "https"
        client.open_timeout = [seconds, 2.0].min
        client.read_timeout = seconds
        client.write_timeout = seconds
        client
      end

      # The core speaks the response envelope on success and on every contract
      # failure, so a JSON body is returned as-is. Anything else is an
      # infrastructure fault and never a silently empty result.
      def decode(response)
        parsed = JSON.parse(response.body.to_s)
        return parsed if parsed.is_a?(Hash)

        raise unexpected(response, "body was not a JSON object")
      rescue JSON::ParserError
        raise unexpected(response, "body was not JSON")
      end

      def unexpected(response, reason)
        @logger.error("unexpected core response", http_status: response.code, reason: reason)
        Kioku::Error.new(
          "kioku.internal_error",
          "the core returned an unreadable response",
          details: { "http_status" => response.code.to_i, "reason" => reason }
        )
      end
    end
  end
end
