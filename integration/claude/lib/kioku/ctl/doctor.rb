# frozen_string_literal: true

require "json"
require "time"

require_relative "hook"
require_relative "../errors"

module Kioku
  module Ctl
    # "Ship ... contextctl doctor. Doctor checks Ruby/provider capabilities, PostgreSQL
    # connectivity/version/extensions, ParadeDB index readiness and coverage,
    # Redis/Sidekiq connectivity, schema and queue readiness ..." [plan §9].
    #
    # The host package never talks to PostgreSQL or Redis itself — it has no database
    # client and Compose publishes no port for either [plan §3.1]. It asks the host agent
    # for a health report and relays what came back. A subsystem that could not be
    # contacted is reported unreachable: an operator command that cannot check something
    # must not report it healthy.
    class Doctor
      Check = Struct.new(:name, :status, :detail, keyword_init: true)

      SUBSYSTEMS = %w[core database redis].freeze
      TEMPLATES = %w[claude-code-hooks.json claude-code-mcp.json].freeze
      HEALTH_DEADLINE_MS = 5_000
      STATUSES = %w[ok degraded unreachable failed].freeze

      def initialize(stdout:, link:, package_root:)
        @stdout = stdout
        @link = link
        @package_root = package_root
      end

      def call(json: false)
        checks = run_checks
        emit(checks, json)
        checks.all? { |check| check.status == "ok" } ? 0 : 1
      end

      private

      def run_checks
        report = agent_report
        [ruby_check, config_check, agent_check(report)] + subsystem_checks(report)
      end

      def agent_report
        @link.call(frame: { "op" => "health" }, deadline_ms: HEALTH_DEADLINE_MS)
      rescue Kioku::Error => e
        { "error" => e.code, "detail" => e.message }
      end

      def ruby_check
        Check.new(name: "ruby", status: "ok", detail: RUBY_DESCRIPTION)
      end

      def config_check
        missing = TEMPLATES.reject { |name| File.file?(template_path(name)) }
        return failed_config("missing templates: #{missing.join(', ')}") if missing.any?

        uncovered = Hook::SUPPORTED_EVENTS - registered_events
        return failed_config("the hook template does not register: #{uncovered.join(', ')}") if uncovered.any?

        Check.new(name: "config", status: "ok",
                  detail: "hook and MCP templates in #{config_dir} cover all " \
                          "#{Hook::SUPPORTED_EVENTS.size} events")
      end

      def registered_events
        JSON.parse(File.read(template_path("claude-code-hooks.json"))).fetch("hooks", {}).keys
      rescue JSON::ParserError, KeyError
        []
      end

      def failed_config(detail)
        Check.new(name: "config", status: "failed", detail: detail)
      end

      def agent_check(report)
        return Check.new(name: "agent", status: "ok", detail: "control connection open on #{@link.socket_path}") if
          reachable?(report)

        Check.new(name: "agent", status: "unreachable",
                  detail: "#{report['detail']} (#{@link.socket_path})")
      end

      def subsystem_checks(report)
        SUBSYSTEMS.map do |name|
          next unreachable_subsystem(name) unless reachable?(report)

          reported = report.dig("subsystems", name)
          Check.new(name: name, status: reported_status(reported), detail: reported_detail(reported))
        end
      end

      def unreachable_subsystem(name)
        Check.new(name: name, status: "unreachable",
                  detail: "not contacted: the host agent reports subsystem health and its link is down")
      end

      # An unknown or missing status is not evidence of health.
      def reported_status(reported)
        status = reported.is_a?(Hash) ? reported["status"] : nil
        STATUSES.include?(status) ? status : "unreachable"
      end

      def reported_detail(reported)
        detail = reported.is_a?(Hash) ? reported["detail"] : nil
        detail.is_a?(String) ? detail : "the host agent reported no detail for this subsystem"
      end

      def reachable?(report)
        report.is_a?(Hash) && report["error"].nil?
      end

      def config_dir
        File.join(@package_root, "config")
      end

      def template_path(name)
        File.join(config_dir, name)
      end

      def emit(checks, json)
        @stdout.puts(json ? json_report(checks) : human_report(checks))
      end

      def json_report(checks)
        JSON.generate("generated_at" => Time.now.utc.iso8601,
                      "checks" => checks.map { |check| check.to_h.transform_keys(&:to_s) })
      end

      def human_report(checks)
        checks.map { |check| format("%-10s %-12s %s", check.name, check.status, check.detail) }.join("\n")
      end
    end
  end
end
