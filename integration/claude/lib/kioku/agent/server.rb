# frozen_string_literal: true

require "socket"
require "fileutils"
require "time"
require_relative "context"
require_relative "router"

module Kioku
  module Agent
    # The persistent host service.
    #
    # It listens on a private Unix socket created 0700/0600 under the user's own
    # directory, and it is the only process in the package that holds the bridge
    # credential or touches approved source. Concurrency is bounded: a fixed
    # number of connection threads, one framed request and response per
    # exchange.
    class Server
      MAX_CONNECTIONS = 16
      REPLAY_INTERVAL_SECONDS = 15

      def initialize(config:, logger:)
        @config = config
        @logger = logger
        @context = Context.new(config: config, logger: logger)
        @router = Router.new(@context)
        @running = false
        @connections = 0
        @mutex = Mutex.new
      end

      def run
        return unsupported unless Kioku::SocketClient.supported?

        @server = bind
        @running = true
        @context.start
        start_replay_loop
        trap_signals
        @logger.info("context-agent listening", socket: @config.socket_path)
        accept_loop
        0
      ensure
        shutdown
      end

      def stop
        @running = false
        @server&.close
      rescue IOError
        nil
      end

      private

      def unsupported
        @logger.error("unix sockets are unavailable on this platform; context-agent cannot start")
        1
      end

      def bind
        path = @config.socket_path
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.unlink(path) if File.socket?(path)
        server = ::UNIXServer.new(path)
        File.chmod(0o600, path)
        server
      end

      def accept_loop
        while @running
          socket = accept
          next if socket.nil?

          reject(socket) || Thread.new { serve(socket) }
        end
      end

      def accept
        @server.accept
      rescue IOError, Errno::EBADF, Errno::EINVAL
        nil
      end

      # Returns truthy when the connection was refused, so the caller does not
      # also spawn a thread for it.
      def reject(socket)
        return false if reserve

        write_error(socket, Kioku::Error.new(
          "kioku.quota_exhausted", "agent connection bound reached",
          details: { "quota_kind" => "connections", "limit" => MAX_CONNECTIONS }
        ))
        close(socket)
        true
      end

      def serve(socket)
        request = Kioku::Frame.read(socket)
        Kioku::Frame.write(socket, handle(request)) unless request.nil?
      rescue Kioku::Error => e
        write_error(socket, e)
      rescue StandardError => e
        @logger.error("agent connection failed", error: e.class.name, detail: e.message)
        write_error(socket, Kioku::Error.new("kioku.internal_error", "the agent failed to handle the request"))
      ensure
        close(socket)
        release
      end

      def handle(request)
        op = request["op"]
        deadline = request["deadline_ms"] || 5_000
        result = @router.call(op, request["payload"], deadline)
        result.is_a?(Hash) && result.key?("status") ? result : { "ok" => true, "op" => op, "result" => result }
      rescue Kioku::Error => e
        error_body(op, e)
      end

      def error_body(op, error)
        {
          "ok" => false, "op" => op, "schema_version" => Kioku::SCHEMA_VERSION,
          "status" => error.status, "error" => error.to_error_object,
          "server_time" => Time.now.utc.iso8601(3)
        }.compact
      end

      def write_error(socket, error)
        Kioku::Frame.write(socket, error_body(nil, error))
      rescue StandardError
        nil
      end

      def start_replay_loop
        Thread.new do
          while @running
            sleep(REPLAY_INTERVAL_SECONDS)
            safely_replay
          end
        end
      end

      def safely_replay
        result = @context.replay.run_once
        @logger.debug("spool replay", **result.transform_keys(&:to_sym))
      rescue StandardError => e
        @logger.warn("spool replay failed", error: e.class.name, detail: e.message)
      end

      def trap_signals
        %w[INT TERM].each { |signal| Signal.trap(signal) { stop } }
      rescue ArgumentError
        nil
      end

      def reserve
        @mutex.synchronize do
          next false if @connections >= MAX_CONNECTIONS

          @connections += 1
          true
        end
      end

      def release
        @mutex.synchronize { @connections -= 1 }
      end

      def close(socket)
        socket.close unless socket.closed?
      rescue IOError, SystemCallError
        nil
      end

      def shutdown
        @context.stop
        File.unlink(@config.socket_path) if File.socket?(@config.socket_path)
      rescue SystemCallError
        nil
      end
    end
  end
end
