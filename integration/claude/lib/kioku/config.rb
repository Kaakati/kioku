# frozen_string_literal: true

require "json"

module Kioku
  # Host configuration for all three entry points. Environment variables win
  # over the on-disk file so an operator can override one value without
  # rewriting the installation. Durable data lives under KIOKU_HOME, never
  # inside a plugin installation directory.
  class Config
    DEFAULT_API_URL = "http://127.0.0.1:7310"
    DEFAULT_SPOOL_MAX_BYTES = 64 * 1024 * 1024
    DEFAULT_HOOK_DEADLINE_MS = 700
    DEFAULT_CONNECT_TIMEOUT_MS = 250

    attr_reader :home, :socket_path, :api_url, :bridge_token, :object_root, :spool_dir,
                :spool_max_bytes, :approved_roots, :projects, :installation_id,
                :hook_deadline_ms, :connect_timeout_ms

    def self.load(env: ENV)
      home = env["KIOKU_HOME"] || File.join(Dir.home, ".kioku")
      new(home: home, file: read_file(File.join(home, "config.json")), env: env)
    end

    def self.read_file(path)
      return {} unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def initialize(home:, file: {}, env: {})
      @home = home
      @file = file
      @env = env
      assign_paths
      assign_bridge
      assign_limits
      @approved_roots = string_list("KIOKU_APPROVED_ROOTS", "approved_roots")
      @projects = @file["projects"].is_a?(Hash) ? @file["projects"] : {}
    end

    def config_path
      File.join(@home, "config.json")
    end

    # Root path -> registered project key. An unknown root stays unresolved; it
    # is never reinterpreted as a global capture.
    def project_key_for(root)
      @projects[root]
    end

    def to_h
      {
        "home" => @home, "socket_path" => @socket_path, "api_url" => @api_url,
        "object_root" => @object_root, "spool_dir" => @spool_dir,
        "spool_max_bytes" => @spool_max_bytes, "approved_roots" => @approved_roots,
        "installation_id" => @installation_id, "bridge_token_present" => !@bridge_token.nil?
      }
    end

    private

    def assign_paths
      @socket_path = value("KIOKU_SOCKET_PATH", "socket_path") || File.join(@home, "run", "agent.sock")
      @object_root = value("KIOKU_OBJECT_ROOT", "object_root") || File.join(@home, "objects")
      @spool_dir = value("KIOKU_SPOOL_DIR", "spool_dir") || File.join(@home, "spool")
    end

    def assign_bridge
      @api_url = value("KIOKU_API_URL", "api_url") || DEFAULT_API_URL
      @bridge_token = value("KIOKU_BRIDGE_TOKEN", "bridge_token")
      @installation_id = value("KIOKU_INSTALLATION_ID", "installation_id")
    end

    def assign_limits
      @spool_max_bytes = integer("KIOKU_SPOOL_MAX_BYTES", "spool_max_bytes", DEFAULT_SPOOL_MAX_BYTES)
      @hook_deadline_ms = integer("KIOKU_HOOK_DEADLINE_MS", "hook_deadline_ms", DEFAULT_HOOK_DEADLINE_MS)
      @connect_timeout_ms = integer("KIOKU_CONNECT_TIMEOUT_MS", "connect_timeout_ms", DEFAULT_CONNECT_TIMEOUT_MS)
    end

    def value(env_key, file_key)
      raw = @env[env_key]
      raw = @file[file_key] if raw.nil? || raw.empty?
      raw.is_a?(String) && !raw.empty? ? raw : nil
    end

    def integer(env_key, file_key, fallback)
      raw = @env[env_key] || @file[file_key]
      parsed = Integer(raw, exception: false)
      parsed&.positive? ? parsed : fallback
    end

    def string_list(env_key, file_key)
      from_env = @env[env_key].to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
      return from_env unless from_env.empty?

      Array(@file[file_key]).select { |item| item.is_a?(String) && !item.empty? }
    end
  end
end
