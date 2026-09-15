# frozen_string_literal: true

require "socket"
require "uri"
require "set"
require "time"

module Kioku
  module Agent
    # The agent-initiated persistent control connection.
    #
    # The agent dials the core and keeps the connection open; the core sends
    # bounded source-validation requests back down it. That is the only way the
    # core reaches the host, so the host exposes no inbound service. Requests
    # are multiplexed by id, each carries its own deadline, a cancel frame
    # retires one in flight, and every reconnect increments an epoch so a late
    # answer from a previous connection is recognisable and discardable.
    #
    # While this channel is down, applicability can only be historical or
    # unknown. It can never be source_checked.
    class ControlChannel
      MAX_IN_FLIGHT = 32
      BACKOFF_SECONDS = [0.5, 1, 2, 5, 10, 30].freeze
      READ_CHUNK = 16_384

      def initialize(api_url:, token:, handler:, logger:, installation_id: nil)
        @uri = URI.parse(api_url)
        @token = token
        @handler = handler
        @logger = logger
        @installation_id = installation_id
        @epoch = 0
        @connected = false
        @cancelled = Set.new
        @in_flight = 0
        @mutex = Mutex.new
        @write_mutex = Mutex.new
        @running = false
      end

      attr_reader :epoch

      def connected?
        @mutex.synchronize { @connected }
      end

      def state
        { "host_link_state" => connected? ? "connected" : "disconnected",
          "reconnect_epoch" => @epoch, "in_flight" => @in_flight }
      end

      def start
        @running = true
        @thread = Thread.new { supervise }
        self
      end

      def stop
        @running = false
        @thread&.kill
        @connected = false
      end

      private

      def supervise
        attempt = 0
        while @running
          ok = run_session
          attempt = ok ? 0 : [attempt + 1, BACKOFF_SECONDS.length - 1].min
          sleep(BACKOFF_SECONDS[attempt]) if @running
        end
      end

      def run_session
        socket = dial
        @mutex.synchronize { @epoch += 1 }
        write_request_head(socket)
        send_frame(socket, hello)
        read_response_head(socket)
        mark(true)
        pump(socket)
        true
      rescue StandardError => e
        @logger.warn("control connection dropped", error: e.class.name, detail: e.message)
        false
      ensure
        mark(false)
        close(socket)
      end

      def dial
        socket = ::Socket.tcp(@uri.host, @uri.port, connect_timeout: 2)
        socket.timeout = 60 if socket.respond_to?(:timeout=)
        socket
      end

      # A chunked POST whose request body carries host frames and whose response
      # body carries core frames: one connection, both directions, no inbound
      # listener on the host.
      def write_request_head(socket)
        lines = [
          "POST /api/v1/host/control HTTP/1.1",
          "Host: #{@uri.host}:#{@uri.port}",
          "Authorization: Bearer #{@token}",
          "Origin: #{@uri.scheme}://#{@uri.host}:#{@uri.port}",
          "X-Kioku-Protocol: #{Kioku::FRAME_PROTOCOL}",
          "X-Kioku-Installation: #{@installation_id}",
          "X-Kioku-Reconnect-Epoch: #{@epoch}",
          "Content-Type: application/vnd.kioku.control",
          "Transfer-Encoding: chunked",
          "", ""
        ]
        socket.write(lines.join("\r\n"))
        socket.flush
      end

      def read_response_head(socket)
        status = socket.gets("\n", 256).to_s
        code = status.split(" ")[1].to_i
        raise "core refused the control connection with status #{code}" unless code == 200

        loop do
          line = socket.gets("\n", 8192).to_s
          break if line.strip.empty? || line.empty?
        end
      end

      def hello
        {
          "type" => "hello", "protocol" => Kioku::FRAME_PROTOCOL,
          "agent_version" => Kioku::VERSION, "reconnect_epoch" => @epoch,
          "capabilities" => %w[source.validate source.manifest source.read],
          "max_in_flight" => MAX_IN_FLIGHT
        }
      end

      def pump(socket)
        buffer = Kioku::FrameBuffer.new
        while @running
          bytes = read_chunk(socket)
          break if bytes.nil?

          buffer << bytes
          buffer.each_frame { |frame| dispatch(socket, frame) }
        end
      end

      # HTTP/1.1 chunked transfer decoding. Returns nil on the terminal chunk.
      def read_chunk(socket)
        size_line = socket.gets("\r\n", 32)
        return nil if size_line.nil?

        size = size_line.strip.split(";").first.to_i(16)
        return nil if size.zero?

        body = socket.read(size)
        socket.read(2)
        body
      end

      def dispatch(socket, frame)
        case frame["type"]
        when "request" then handle_request(socket, frame)
        when "cancel" then @mutex.synchronize { @cancelled << frame["id"] }
        when "ping" then send_frame(socket, { "type" => "pong", "epoch" => @epoch })
        else @logger.debug("ignored control frame", type: frame["type"])
        end
      end

      def handle_request(socket, frame)
        return send_frame(socket, overloaded(frame)) unless reserve

        Thread.new { run_request(socket, frame) }
      end

      def run_request(socket, frame)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = @handler.call(frame["op"], frame["payload"] || {})
        send_frame(socket, answer(frame, result, started))
      rescue Kioku::Error => e
        send_frame(socket, { "type" => "response", "id" => frame["id"], "epoch" => @epoch,
                             "error" => e.to_error_object })
      ensure
        release(frame["id"])
      end

      # A late answer is not sent: the core would have to decide whether it
      # still applies, and the contract says a late validation cannot satisfy a
      # newer request or source epoch.
      def answer(frame, result, started)
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        deadline = frame["deadline_ms"].to_i
        if deadline.positive? && elapsed_ms > deadline
          return { "type" => "response", "id" => frame["id"], "epoch" => @epoch,
                   "error" => Kioku::Error.new("kioku.deadline_exceeded",
                                               "host validation exceeded the request deadline").to_error_object }
        end

        { "type" => "response", "id" => frame["id"], "epoch" => @epoch,
          "elapsed_ms" => elapsed_ms, "result" => result }
      end

      def overloaded(frame)
        { "type" => "response", "id" => frame["id"], "epoch" => @epoch,
          "error" => Kioku::Error.new(
            "kioku.quota_exhausted", "host control channel is at its in-flight bound",
            details: { "quota_kind" => "control_in_flight", "limit" => MAX_IN_FLIGHT }
          ).to_error_object }
      end

      def reserve
        @mutex.synchronize do
          next false if @in_flight >= MAX_IN_FLIGHT

          @in_flight += 1
          true
        end
      end

      def release(id)
        @mutex.synchronize do
          @in_flight -= 1
          @cancelled.delete(id)
        end
      end

      def cancelled?(id)
        @mutex.synchronize { @cancelled.include?(id) }
      end

      def send_frame(socket, frame)
        return if frame["id"] && cancelled?(frame["id"])

        body = JSON.generate(frame).b
        payload = +"#{Kioku::FRAME_PROTOCOL} #{body.bytesize}\n"
        payload << body
        @write_mutex.synchronize { write_chunk(socket, payload) }
      end

      def write_chunk(socket, payload)
        socket.write(format("%x\r\n", payload.bytesize))
        socket.write(payload)
        socket.write("\r\n")
        socket.flush
      end

      def mark(value)
        @mutex.synchronize { @connected = value }
      end

      def close(socket)
        socket&.close
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
