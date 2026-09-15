# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"

module Kioku
  module Agent
    # The server end of the private host control connection:
    # "context-mcp (stdio) -> private host Unix socket -> context-agent"
    # [contracts: envelope.transport_and_actor.path; plan §3.1].
    #
    # This is the ONLY thing the host listens on, and it is a Unix socket in the
    # user's own runtime directory rather than a TCP port: "the host does not
    # expose another inbound service". The connection to the core runs the other
    # way and is opened by the agent.
    #
    # Frames are newline-delimited JSON, one request and one response per
    # connection, matching Kioku::HostLink on the client side. Every connection
    # is answered: a control connection that closed silently would be
    # indistinguishable, to a caller, from a save still in flight.
    class Server
      MAX_FRAME_BYTES = 4 * 1024 * 1024
      READ_TIMEOUT_SECONDS = 30.0
      SOCKET_MODE = 0o600

      def initialize(socket_path:, handler:, logger:)
        @socket_path = socket_path
        @handler = handler
        @logger = logger
      end

      def run
        listen
        accept_loop
      ensure
        shutdown
      end

      private

      def listen
        FileUtils.mkdir_p(File.dirname(@socket_path))
        # A socket file left by a killed run is a name, not a listener; binding
        # over it is what makes a restart work.
        FileUtils.rm_f(@socket_path)
        @server = UNIXServer.new(@socket_path)
        restrict
        @logger.info("listening on #{@socket_path}")
      end

      # The socket is the whole host authority boundary: anything that can
      # connect can ask the agent to spool a capture and to reach the core. A
      # host that cannot express owner-only access is told so rather than left
      # silently open.
      def restrict
        File.chmod(SOCKET_MODE, @socket_path)
      rescue SystemCallError, NotImplementedError
        @logger.warn("could not restrict #{@socket_path} to owner-only access")
      end

      # One thread per connection so a client that stops mid-frame cannot wedge
      # the agent for every other caller. The handler serializes itself, because
      # the spool is one durable log.
      def accept_loop
        loop do
          connection = @server.accept
          Thread.new { serve(connection) }
        end
      rescue Errno::EBADF, IOError, Errno::EINVAL
        nil
      end

      def serve(connection)
        frame = read_frame(connection)
        write_frame(connection, @handler.call(frame: frame)) unless frame.nil?
      rescue StandardError => error
        @logger.error("control connection failed: #{error.class}")
      ensure
        close(connection)
      end

      def read_frame(connection)
        buffer = +""
        deadline = monotonic + READ_TIMEOUT_SECONDS
        loop do
          index = buffer.index("\n")
          return parse(buffer[0...index]) if index
          return nil if buffer.bytesize > MAX_FRAME_BYTES

          chunk = read_chunk(connection, deadline - monotonic)
          return nil if chunk.nil?

          buffer << chunk
        end
      end

      def read_chunk(connection, remaining)
        return nil if remaining <= 0 || !connection.wait_readable(remaining)

        connection.read_nonblock(65_536)
      rescue IO::WaitReadable
        ""
      rescue EOFError, SystemCallError, IOError
        nil
      end

      def parse(line)
        JSON.parse(line)
      rescue JSON::ParserError
        @logger.warn("a control frame was not valid JSON")
        nil
      end

      def write_frame(connection, response)
        connection.write("#{JSON.generate(response)}\n")
        connection.flush
      rescue SystemCallError, IOError
        @logger.warn("the caller closed the control connection before the answer was written")
      end

      def close(connection)
        connection&.close
      rescue IOError, SystemCallError
        nil
      end

      def shutdown
        @server&.close
      rescue IOError, SystemCallError
        nil
      ensure
        FileUtils.rm_f(@socket_path)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
