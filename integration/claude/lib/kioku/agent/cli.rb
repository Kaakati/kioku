# frozen_string_literal: true

require_relative "server"

module Kioku
  module Agent
    # bin/context-agent. The persistent host service runs in the foreground and
    # is supervised by the operator's own service manager; it does not
    # daemonise itself or write a pid file it would then have to reconcile.
    class Cli
      def initialize(argv, stdout: $stdout, stderr: $stderr)
        @argv = argv.dup
        @command = @argv.shift || "run"
        @stdout = stdout
        @stderr = stderr
      end

      def run
        case @command
        when "run" then serve
        when "version", "--version" then version
        when "help", "--help", "-h" then usage
        else unknown
        end
      end

      private

      def serve
        config = Kioku::Config.load
        logger = Kioku::Logger.new(component: "context-agent", io: @stderr,
                                   level: ENV.fetch("KIOKU_LOG_LEVEL", "info"))
        Server.new(config: config, logger: logger).run
      end

      def version
        @stdout.puts("context-agent #{Kioku::VERSION} (contract #{Kioku::SCHEMA_VERSION})")
        0
      end

      def unknown
        @stderr.puts("unknown command: #{@command}")
        usage
        2
      end

      def usage
        @stdout.puts(<<~TEXT)
          context-agent [run]

            run       Listen on the private Unix socket, hold the authenticated loopback
                      control connection to the core, and drain the durable host spool.
            version   Print the version and contract id.

          Stop it with SIGINT or SIGTERM; in-flight work is bounded by its own deadlines.
        TEXT
        0
      end
    end
  end
end
