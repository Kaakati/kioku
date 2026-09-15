# frozen_string_literal: true

require_relative "../host_link"
require_relative "../logger"

module Kioku
  module Ctl
    # "contextctl | Bounded stdin decoding, event dispatch, pairing/doctor/operator
    # commands | stdout is event-specific output; diagnostics use stderr" [plan §3].
    #
    # Commands are required lazily: a hook invocation runs on every prompt and every tool
    # call, so it loads the hook path and nothing else.
    class Command
      USAGE = "usage: contextctl <hook|doctor [--json]>"
      EXIT_USAGE = 64

      def initialize(argv:, stdin:, stdout:, stderr:)
        @argv = argv
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
      end

      def call
        case @argv.first
        when "hook" then hook
        when "doctor" then doctor
        else usage
        end
      end

      private

      def hook
        require_relative "hook"
        logger = Logger.new(program: "contextctl", stream: @stderr)
        Hook.new(stdin: @stdin, stdout: @stdout, logger: logger,
                 link: HostLink.new(logger: nil)).call
      end

      def doctor
        require_relative "doctor"
        Doctor.new(stdout: @stdout, link: HostLink.new(logger: nil), package_root: package_root)
              .call(json: @argv.include?("--json"))
      end

      def package_root
        File.expand_path("../../..", __dir__)
      end

      def usage
        @stderr.puts(USAGE)
        EXIT_USAGE
      end
    end
  end
end
