# frozen_string_literal: true

require "json"
require "time"
require_relative "approved_roots"
require_relative "agent/bridge"
require_relative "doctor/checks"

module Kioku
  # `contextctl doctor`: the operator's single readiness command.
  #
  # It reports Claude capability, the host socket and agent, approved roots, the
  # durable spool, the authenticated loopback core, whatever PostgreSQL and
  # ParadeDB state the core reports, and Docker reachability. A check that
  # cannot observe something says so; it never reports healthy by default.
  class Doctor
    ORDER = %w[ruby_runtime mcp_sdk claude_client claude_registration approved_roots
               socket spool core database docker].freeze

    def initialize(config:, logger:, stdout: $stdout)
      @config = config
      @logger = logger
      @stdout = stdout
      @checks = Checks.new(config: config, logger: logger)
    end

    def run(json: false)
      report = build_report
      json ? print_json(report) : print_text(report)
      failed?(report) ? 1 : 0
    end

    def build_report
      results = ORDER.map { |name| safely(name) }
      {
        "kioku_version" => Kioku::VERSION,
        "schema_version" => Kioku::SCHEMA_VERSION,
        "checked_at" => Time.now.utc.iso8601(3),
        "config" => @config.to_h,
        "checks" => results
      }
    end

    private

    def safely(name)
      @checks.public_send(name)
    rescue StandardError => e
      { "name" => name, "state" => "fail", "detail" => "check raised #{e.class.name}", "data" => {} }
    end

    def failed?(report)
      report["checks"].any? { |check| check["state"] == "fail" }
    end

    def print_json(report)
      @stdout.puts(JSON.pretty_generate(report))
    end

    def print_text(report)
      @stdout.puts("kioku #{report['kioku_version']}  contract #{report['schema_version']}")
      report["checks"].each { |check| @stdout.puts(line(check)) }
      @stdout.puts(summary(report))
    end

    def line(check)
      format("%-6s %-20s %s", marker(check["state"]), check["name"], check["detail"])
    end

    def marker(state)
      { "ok" => "[ok]", "warn" => "[warn]", "fail" => "[FAIL]", "skipped" => "[--]" }.fetch(state, "[?]")
    end

    def summary(report)
      counts = report["checks"].group_by { |check| check["state"] }.transform_values(&:length)
      "#{counts.fetch('ok', 0)} ok, #{counts.fetch('warn', 0)} warn, #{counts.fetch('fail', 0)} failing"
    end
  end
end
