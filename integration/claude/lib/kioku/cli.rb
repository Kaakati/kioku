# frozen_string_literal: true

require "json"
require_relative "hooks/dispatcher"

# Kioku::Doctor and Kioku::Cli::Pair are required inside their own commands, not
# here. Doctor pulls in net/http, which measurably doubles interpreter startup,
# and startup sits inside the one-second hook timeout. The hook path loads only
# the core package and the dispatcher.

module Kioku
  # bin/contextctl. Hook dispatch plus the operator commands.
  #
  # `hook` writes only the event's own output to stdout and always exits 0:
  # a memory subsystem must never block or fail a Claude session. The operator
  # commands are ordinary CLI programs and do use exit codes.
  class Cli
    COMMANDS = %w[hook doctor status spool pair version help].freeze

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @command = @argv.shift
      @stdout = stdout
      @stderr = stderr
      @config = Kioku::Config.load
    end

    def run
      case @command
      when "hook" then hook
      when "doctor" then doctor
      when "status" then status
      when "spool" then spool
      when "pair" then pair
      when "version", "--version" then version
      when nil, "help", "--help", "-h" then usage
      else unknown
      end
    end

    private

    def logger(component)
      Kioku::Logger.new(component: component, io: @stderr)
    end

    def hook
      Kioku::Hooks::Dispatcher.new(config: @config, logger: logger("contextctl-hook")).run
    end

    def doctor
      require_relative "doctor"
      Kioku::Doctor.new(config: @config, logger: logger("contextctl-doctor"), stdout: @stdout)
                   .run(json: @argv.include?("--json"))
    end

    def pair
      require_relative "cli/pair"
      Pair.new(config: @config, stdout: @stdout).run(@argv)
    end

    def status
      response = agent_call("agent.health")
      return 1 if response.nil?

      @stdout.puts(JSON.pretty_generate(response["result"] || response))
      0
    end

    def spool
      case @argv.first
      when "replay" then print_agent("spool.replay")
      when nil, "status" then print_spool_status
      else unknown_subcommand
      end
    end

    def print_spool_status
      @stdout.puts(JSON.pretty_generate(Kioku.spool_for(@config).stats))
      0
    end

    def print_agent(op)
      response = agent_call(op)
      return 1 if response.nil?

      @stdout.puts(JSON.pretty_generate(response["result"] || response))
      0
    end

    def agent_call(op)
      client = Kioku::SocketClient.new(path: @config.socket_path, connect_timeout_ms: 1_000)
      response = client.call(op: op, deadline_ms: 5_000)
      client.close
      response
    rescue Kioku::Error => e
      @stderr.puts("context-agent unavailable at #{@config.socket_path}: #{e.message}")
      nil
    end

    def version
      @stdout.puts("contextctl #{Kioku::VERSION} (contract #{Kioku::SCHEMA_VERSION})")
      0
    end

    def unknown
      @stderr.puts("unknown command: #{@command}")
      usage
      2
    end

    def unknown_subcommand
      @stderr.puts("unknown spool subcommand: #{@argv.first}")
      2
    end

    def usage
      @stdout.puts(<<~TEXT)
        contextctl <command>

          hook                  Dispatch one Claude Code hook event read from stdin.
          doctor [--json]       Check Claude, host socket, roots, spool, core and Docker.
          status                Print context-agent health.
          spool [status|replay] Inspect or drain the durable host spool.
          pair --token TOKEN    Write the host installation configuration.
          version               Print the version and contract id.

        Commands: #{COMMANDS.join(', ')}
      TEXT
      0
    end
  end
end
