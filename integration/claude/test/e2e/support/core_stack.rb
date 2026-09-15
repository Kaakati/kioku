# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"

module Kioku
  module TestSupport
    # The running Compose stack, as the host package sees it.
    #
    # The host adapter and the stack share one .env (".env ... the host adapter
    # in ./integration/claude reads the same .env file"), so the bridge
    # credential and the loopback port are read from there rather than invented.
    #
    # Nothing here skips. An end-to-end case whose core is not running has not
    # been satisfied, and reporting that as a pass is the same class of untruth
    # the whole contract is about. It fails, and the message names the command
    # that fixes it.
    module CoreStack
      REPO_ROOT = File.expand_path("../../../../..", __dir__)
      DEFAULT_CORE_URL = "http://127.0.0.1:7310"
      MARKER = "KIOKU_E2E_FIXTURE"

      module_function

      def dotenv
        @dotenv ||= parse_dotenv(File.join(REPO_ROOT, ".env"))
      end

      def parse_dotenv(path)
        return {} unless File.file?(path)

        File.readlines(path, chomp: true).each_with_object({}) do |line, values|
          next if line.strip.empty? || line.strip.start_with?("#")

          key, _, value = line.partition("=")
          values[key.strip] = value.strip
        end
      end

      def core_url
        ENV["KIOKU_CORE_URL"] || DEFAULT_CORE_URL
      end

      def bridge_token
        ENV["KIOKU_BRIDGE_TOKEN"] || dotenv["KIOKU_BRIDGE_TOKEN"] || ""
      end

      def installation_key
        ENV["KIOKU_BRIDGE_INSTALLATION_KEY"] || dotenv["KIOKU_BRIDGE_INSTALLATION_KEY"] ||
          "installation-e2e"
      end

      # 200 from /up means database connectivity and schema presence were both
      # confirmed (routes.rb: "Readiness, not liveness").
      def readiness_failure
        response = Net::HTTP.get_response(URI.join(core_url, "/up"))
        return nil if response.code == "200"

        "GET #{core_url}/up answered #{response.code}"
      rescue StandardError => error
        "GET #{core_url}/up raised #{error.class}: #{error.message}"
      end

      # Registers the installation the bridge credential is paired to, the
      # project the write is destined for, its authorization scope, and one
      # durable retained object for the evidence link — the rows plan §7.1 step 4
      # says the core validates a write against, and which no tool in the frozen
      # six-tool surface creates ("Project registration and root management
      # belong to operator/UI setup APIs").
      def arrange_remember_fixture(project_key:)
        stdout, stderr, status = Open3.capture3(
          "docker", "compose", "exec", "-T", "api", "bundle", "exec", "rails", "runner", "-",
          stdin_data: fixture_script(project_key), chdir: REPO_ROOT
        )
        line = stdout.lines.map(&:strip).find { |candidate| candidate.start_with?(MARKER) }
        return JSON.parse(line.delete_prefix("#{MARKER} ")) if status.success? && line

        raise "could not arrange the e2e fixture in the running stack " \
              "(exit #{status.exitstatus}): #{stderr[-800, 800] || stderr}#{stdout[-400, 400]}"
      rescue Errno::ENOENT
        raise "the docker CLI is not available, so the e2e fixture cannot be arranged"
      end

      def fixture_script(project_key)
        <<~RUBY
          connection = ActiveRecord::Base.connection
          installation = #{installation_key.inspect}
          project = #{project_key.inspect}
          object = "object-e2e-" + SecureRandom.uuid_v7
          quote = ->(value) { connection.quote(value) }

          connection.execute("INSERT INTO installations (installation_key) VALUES (" +
            quote.(installation) + ") ON CONFLICT DO NOTHING")
          connection.execute("INSERT INTO projects (project_key, display_name, lifecycle) VALUES (" +
            quote.(project) + ", " + quote.(project) + ", 'active') ON CONFLICT DO NOTHING")
          connection.execute("INSERT INTO scopes (scope_key, installation_key, scope_kind, project_key, subject_key)" +
            " VALUES (" + quote.("scope-" + project) + ", " + quote.(installation) + ", 'project', " +
            quote.(project) + ", " + quote.(project) + ") ON CONFLICT DO NOTHING")
          connection.execute("INSERT INTO source_objects (object_key, content_hash, hash_algorithm," +
            " byte_length, availability, stored_at) VALUES (" + quote.(object) + ", " +
            quote.("sha256:" + Digest::SHA256.hexdigest(object)) + ", 'sha256', 11, 'available', now())")

          puts "#{MARKER} " + JSON.generate({ "project_key" => project, "object_key" => object,
                                              "installation_key" => installation })
        RUBY
      end
    end
  end
end
