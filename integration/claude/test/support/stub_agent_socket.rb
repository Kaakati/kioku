# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"
require "tmpdir"

module Kioku
  module TestSupport
    # A stand-in for context-agent that answers one framed request per connection.
    #
    # Why this exists: the degradation tests could only observe an ABSENT socket.
    # With no agent, the hook's stdout is empty by construction, so asserting that
    # no durability label appears in it passed for every conceivable implementation
    # — including one that rendered `"saved": true`. Nothing was being tested.
    #
    # A stub that answers with a real `queued` frame is the scenario the invariant
    # is actually about: the agent reported a durable enqueue, and the hook must
    # not promote that into a save. Callers assert on `requests` too, so a hook
    # that never made contact cannot pass by silence.
    class StubAgentSocket
      FRAME_TERMINATOR = "\n"

      attr_reader :path, :requests

      def self.serving(reply)
        stub = new(reply).start
        yield stub
      ensure
        stub&.stop
      end

      def initialize(reply)
        @reply = reply
        @requests = []
        @dir = Dir.mktmpdir("kioku-stub-agent")
        @path = File.join(@dir, "agent.sock")
      end

      def start
        @server = UNIXServer.new(path)
        @thread = Thread.new { serve }
        self
      end

      def stop
        @thread&.kill
        @server&.close
      rescue StandardError
        nil
      ensure
        FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
      end

      private

      # Frames are newline-delimited JSON, matching Kioku::HostLink#read_frame.
      def serve
        loop do
          socket = @server.accept
          @requests << socket.gets(FRAME_TERMINATOR)
          socket.write("#{JSON.generate(@reply)}#{FRAME_TERMINATOR}")
          socket.flush
          socket.close
        end
      rescue IOError, Errno::EBADF, Errno::ECONNRESET
        nil
      end
    end
  end
end
