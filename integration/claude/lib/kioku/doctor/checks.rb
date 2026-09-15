# frozen_string_literal: true

require_relative "probe"

module Kioku
  class Doctor
    # The individual diagnostic checks. Each returns
    # {name, state, detail, data} where state is ok, warn, fail or skipped.
    # A check reports what it actually observed; it never infers a healthy
    # component from the absence of evidence.
    class Checks
      MIN_RUBY = Gem::Version.new("3.2.0")
      SETTINGS_CANDIDATES = ["settings.json", "settings.local.json"].freeze

      def initialize(config:, logger:)
        @config = config
        @logger = logger
      end

      def ruby_runtime
        version = Gem::Version.new(RUBY_VERSION)
        state = version >= MIN_RUBY ? "ok" : "fail"
        result("ruby_runtime", state, "Ruby #{RUBY_VERSION} #{RUBY_PLATFORM}", { "version" => RUBY_VERSION })
      end

      def mcp_sdk
        spec = Gem::Specification.find_by_name("mcp")
        result("mcp_sdk", "ok", "mcp gem #{spec.version}", { "version" => spec.version.to_s })
      rescue Gem::LoadError
        result("mcp_sdk", "fail", "the mcp gem is not installed; context-mcp cannot start")
      end

      # Claude capability: the client binary and whether Kioku is registered in
      # any settings file this host can see.
      def claude_client
        probe = Probe.run(["claude", "--version"], timeout: 5)
        return result("claude_client", "warn", "claude executable not found on PATH") unless probe.ran

        state = probe.success ? "ok" : "warn"
        result("claude_client", state, probe.output.lines.first.to_s.strip)
      end

      def claude_registration
        files = settings_files
        registered = files.select { |path| mentions_kioku?(path) }
        return result("claude_registration", "warn", "no settings file mentions contextctl or context-mcp",
                      { "searched" => files }) if registered.empty?

        result("claude_registration", "ok", "registered in #{registered.length} settings file(s)",
               { "files" => registered })
      end

      def approved_roots
        roots = Kioku::ApprovedRoots.new(@config.approved_roots)
        return result("approved_roots", "warn", "no approved root is configured; no source can be read") if roots.empty?

        state = roots.unresolved.empty? ? "ok" : "warn"
        result("approved_roots", state, "#{roots.roots.length} approved root(s)",
               { "roots" => roots.roots, "unresolved" => roots.unresolved })
      end

      def socket
        return result("socket", "fail", "Unix sockets are unavailable on this platform") unless supported?
        return result("socket", "fail", "no socket at #{@config.socket_path}") unless File.socket?(@config.socket_path)

        health = agent_health
        return result("socket", "fail", "context-agent did not answer", health) if health.nil?

        result("socket", "ok", "context-agent answered", health)
      end

      def spool
        stats = Kioku.spool_for(@config).stats
        pending = stats["pending_count"]
        state = stats["pending_bytes"] >= stats["max_bytes"] ? "fail" : "ok"
        detail = "#{pending} pending, #{stats['pending_bytes']} of #{stats['max_bytes']} bytes"
        result("spool", state, detail, stats)
      end

      # Readiness of the core as the host can honestly observe it, plus whatever
      # PostgreSQL and ParadeDB state the core chose to report. Nothing is
      # assumed about extensions the core did not name.
      def core
        return result("core", "warn", "no bridge token is configured") if @config.bridge_token.nil?

        health = bridge.health
        return result("core", "fail", "#{@config.api_url} unreachable: #{health['detail']}") unless health["reachable"]

        body = health["body"] || {}
        result("core", body["error"] ? "fail" : "ok", "#{@config.api_url}/up answered", body)
      end

      def database
        body = bridge_body
        return result("database", "warn", "the core did not answer; database state unknown") if body.nil?

        reported = body.slice("database", "schema", "extensions", "postgresql_version", "paradedb")
        return result("database", "warn", "the core did not report database or extension state") if reported.empty?

        result("database", database_state(reported), "reported by the core", reported)
      end

      def docker
        version = Probe.run(["docker", "version", "--format", "{{.Server.Version}}"], timeout: 8)
        return result("docker", "warn", "docker executable not found on PATH") unless version.ran
        return result("docker", "fail", "docker daemon not reachable", { "output" => version.output }) unless version.success

        result("docker", "ok", "docker server #{version.output}", compose_state)
      end

      private

      def result(name, state, detail, data = {})
        { "name" => name, "state" => state, "detail" => detail, "data" => data }
      end

      def supported?
        Kioku::SocketClient.supported?
      end

      def agent_health
        client = Kioku::SocketClient.new(path: @config.socket_path, connect_timeout_ms: 500, logger: @logger)
        response = client.call(op: "agent.health", deadline_ms: 2_000)
        client.close
        response["result"] || response
      rescue Kioku::Error
        nil
      end

      def bridge
        @bridge ||= Kioku::Agent::Bridge.new(
          api_url: @config.api_url, token: @config.bridge_token,
          logger: @logger, installation_id: @config.installation_id
        )
      end

      def bridge_body
        return nil if @config.bridge_token.nil?

        health = bridge.health
        health["reachable"] ? health["body"] : nil
      end

      def database_state(reported)
        return "fail" if reported["database"].to_s == "down"
        return "warn" if reported["extensions"].nil?

        missing = %w[pg_search vector] - Array(reported["extensions"])
        missing.empty? ? "ok" : "fail"
      end

      def compose_state
        probe = Probe.run(["docker", "compose", "ps", "--format", "json"], timeout: 10)
        return {} unless probe.ran && probe.success

        { "compose_ps" => probe.output.lines.first(12).map(&:strip) }
      end

      def settings_files
        roots = [File.join(Dir.home, ".claude"), Dir.pwd, File.join(Dir.pwd, ".claude")]
        (roots.product(SETTINGS_CANDIDATES).map { |dir, name| File.join(dir, name) } +
          [File.join(Dir.pwd, ".mcp.json")]).select { |path| File.file?(path) }
      end

      def mentions_kioku?(path)
        File.read(path, 65_536).to_s.match?(/contextctl|context-mcp/)
      rescue SystemCallError
        false
      end
    end
  end
end
