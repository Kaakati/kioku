# frozen_string_literal: true

require "open3"
require "rbconfig"

module Kioku
  module TestSupport
    # Runs the real bin/context-agent as a separate process, the way Claude Code
    # would.
    #
    # Plan §3.1: "the agent initiates a persistent authenticated control
    # connection to the core; the host does not expose another inbound service."
    # So the agent is the only process in the host package that speaks to the
    # core, and it is the only one that listens on the private Unix socket.
    # context-mcp reaches it as a client through Kioku::HostLink, which is
    # already written against exactly this: newline-delimited JSON frames on a
    # UNIXSocket at KIOKU_SOCKET_PATH.
    #
    # Configuration, all of it environment rather than request text:
    #   KIOKU_SOCKET_PATH    where the agent listens
    #   KIOKU_SPOOL_DIR      the durable bounded spool's directory
    #   KIOKU_CORE_URL       base URL of the authenticated loopback bridge
    #   KIOKU_BRIDGE_TOKEN   the shared secret that bridge authenticates with
    class AgentProcess
      READY_TIMEOUT = 15.0

      attr_reader :socket_path, :spool_dir

      def initialize(socket_path:, spool_dir:, core_url:, bridge_token:)
        @socket_path = socket_path
        @spool_dir = spool_dir
        @core_url = core_url
        @bridge_token = bridge_token
        @stderr_buffer = +""
        @stderr_lock = Mutex.new
      end

      def self.binary_path
        File.join(KIOKU_PACKAGE_ROOT, "bin", "context-agent")
      end

      def self.available?
        File.file?(binary_path)
      end

      def start
        @stdin, @stdout, @stderr, @wait = Open3.popen3(env, RbConfig.ruby, self.class.binary_path)
        @stderr_thread = Thread.new { drain(@stderr) }
        @stdout_thread = Thread.new { drain(@stdout) }
        await_socket
        self
      end

      def stop
        Process.kill("KILL", @wait.pid) if @wait&.alive?
      rescue Errno::ESRCH, Errno::EPERM, RangeError
        nil
      ensure
        close_streams
      end

      def diagnostics
        @stderr_lock.synchronize { @stderr_buffer.dup }
      end

      def alive?
        @wait&.alive?
      end

      private

      def env
        {
          "KIOKU_SOCKET_PATH" => @socket_path,
          "KIOKU_SPOOL_DIR" => @spool_dir,
          "KIOKU_CORE_URL" => @core_url,
          "KIOKU_BRIDGE_TOKEN" => @bridge_token,
          "BUNDLE_GEMFILE" => File.join(KIOKU_PACKAGE_ROOT, "Gemfile")
        }
      end

      # The agent is ready when the socket it owns exists. Polling the socket
      # rather than a banner keeps stdout free and matches how context-mcp
      # decides the agent is reachable (HostLink#available?).
      def await_socket
        deadline = Clock.monotonic + READY_TIMEOUT
        until File.exist?(@socket_path)
          raise ProtocolTimeout, ready_failure if Clock.monotonic > deadline || !@wait.alive?

          sleep 0.05
        end
      end

      def ready_failure
        "bin/context-agent did not create #{@socket_path} within #{READY_TIMEOUT}s " \
          "(alive: #{@wait.alive?}); stderr: #{diagnostics[0, 800].inspect}"
      end

      def drain(stream)
        loop { @stderr_lock.synchronize { @stderr_buffer << stream.readpartial(4096) } }
      rescue EOFError, IOError, Errno::EIO, Errno::EBADF
        nil
      end

      def close_streams
        [@stdin, @stdout, @stderr].each do |stream|
          stream&.close unless stream.nil? || stream.closed?
        rescue IOError, Errno::EPIPE
          nil
        end
        @wait&.join(2.0)
        [@stderr_thread, @stdout_thread].each { |thread| thread&.join(1.0) }
      end
    end
  end
end
