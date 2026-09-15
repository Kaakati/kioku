# frozen_string_literal: true

require "json"
require "socket"

require_relative "errors"

module Kioku
  # The client side of the private host control connection:
  # "context-mcp (stdio) -> private host Unix socket -> context-agent"
  # [contracts: envelope.transport_and_actor.path; plan §3.1].
  #
  # Frames are newline-delimited JSON. The link holds no storage authority and invents no
  # answer: when the agent cannot be reached, or does not answer inside the caller's
  # deadline, the caller gets kioku.source_unavailable rather than an empty result set.
  class HostLink
    DEFAULT_SOCKET_PATH = File.join(Dir.home, ".kioku", "run", "agent.sock")
    MAX_FRAME_BYTES = 4 * 1024 * 1024

    attr_reader :socket_path

    def initialize(socket_path: ENV["KIOKU_SOCKET_PATH"] || DEFAULT_SOCKET_PATH, logger: nil)
      @socket_path = socket_path
      @logger = logger
    end

    def available?
      supported? && File.exist?(@socket_path)
    end

    def call(frame:, deadline_ms:)
      deadline = monotonic + (deadline_ms / 1000.0)
      socket = connect
      begin
        socket.write("#{JSON.generate(frame)}\n")
        socket.flush
        decode(read_frame(socket, deadline))
      ensure
        close(socket)
      end
    end

    private

    def supported?
      defined?(::UNIXSocket) ? true : false
    end

    def connect
      unavailable!("no host agent socket is present at the configured path") unless available?

      ::UNIXSocket.new(@socket_path)
    rescue SystemCallError, IOError
      unavailable!("the host agent refused the control connection")
    end

    def read_frame(socket, deadline)
      buffer = +""
      loop do
        remaining = deadline - monotonic
        unavailable!("the host agent did not answer inside the request deadline") if remaining <= 0
        unavailable!("the host agent stopped answering") unless socket.wait_readable(remaining)

        chunk = read_chunk(socket)
        buffer << chunk
        index = buffer.index("\n")
        return buffer[0...index] if index
        unavailable!("the host agent sent an oversized frame") if buffer.bytesize > MAX_FRAME_BYTES
      end
    end

    def read_chunk(socket)
      socket.read_nonblock(65_536)
    rescue IO::WaitReadable
      ""
    rescue EOFError, SystemCallError, IOError
      unavailable!("the host agent closed the control connection")
    end

    def decode(line)
      JSON.parse(line)
    rescue JSON::ParserError
      unavailable!("the host agent sent a frame that is not valid JSON")
    end

    def close(socket)
      socket&.close
    rescue IOError, SystemCallError
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def unavailable!(detail)
      @logger&.warn(detail)
      raise Kioku::Error.new("kioku.source_unavailable", message: detail,
                                                        details: { "host_link_state" => "disconnected" })
    end
  end
end
