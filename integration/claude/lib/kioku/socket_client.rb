# frozen_string_literal: true

require "socket"

module Kioku
  # Client for the private Unix socket owned by context-agent. Both the hook CLI
  # and the MCP adapter reach the core only through here: neither holds storage
  # authority, and neither opens the loopback bridge itself.
  #
  # Every failure to reach the agent raises TransportUnavailable, which callers
  # translate into their own degradation: the hook returns without enhancement,
  # the MCP adapter reports the failure without claiming a result or a save.
  class SocketClient
    def initialize(path:, connect_timeout_ms: 250, logger: nil)
      @path = path
      @connect_timeout = connect_timeout_ms / 1000.0
      @logger = logger
      @socket = nil
      @mutex = Mutex.new
    end

    attr_reader :path

    def self.supported?
      defined?(::UNIXSocket) ? true : false
    end

    def available?
      File.socket?(@path)
    rescue SystemCallError
      false
    end

    # Sends one framed request and reads one framed response. Reconnects once if
    # a pooled connection was closed by the agent between calls.
    def call(op:, payload: {}, deadline_ms: 5_000)
      @mutex.synchronize do
        begin
          exchange(op, payload, deadline_ms)
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError, Kioku::TransportUnavailable
          close_locked
          exchange(op, payload, deadline_ms)
        end
      end
    end

    def close
      @mutex.synchronize { close_locked }
    end

    private

    def exchange(op, payload, deadline_ms)
      socket = connect
      socket.timeout = (deadline_ms / 1000.0) + 0.5 if socket.respond_to?(:timeout=)
      Kioku::Frame.write(socket, request_body(op, payload, deadline_ms))
      response = Kioku::Frame.read(socket)
      raise Kioku::TransportUnavailable.new("context-agent", "closed before responding") if response.nil?

      response
    rescue IO::TimeoutError
      close_locked
      raise Kioku::Error.new("kioku.deadline_exceeded", "context-agent did not answer within the deadline")
    end

    def request_body(op, payload, deadline_ms)
      {
        "protocol" => Kioku::FRAME_PROTOCOL,
        "op" => op,
        "deadline_ms" => deadline_ms,
        "payload" => payload
      }
    end

    def connect
      return @socket if @socket && !@socket.closed?

      unless self.class.supported?
        raise Kioku::TransportUnavailable.new("context-agent", "Unix sockets are unavailable on this platform")
      end

      @socket = open_socket
    end

    # Every reason the socket cannot be opened -- missing, refused, not
    # permitted, or a path too long for sun_path -- is the same fact to a
    # caller: the agent is not reachable, so degrade.
    def open_socket
      ::Socket.unix(@path)
    rescue SystemCallError, SocketError, ArgumentError => e
      raise Kioku::TransportUnavailable.new("context-agent", "#{e.class.name}: #{e.message}")
    end

    def close_locked
      @socket.close if @socket && !@socket.closed?
    rescue IOError, SystemCallError
      nil
    ensure
      @socket = nil
    end
  end
end
