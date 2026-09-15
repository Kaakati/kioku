# frozen_string_literal: true

require "json"
require "fileutils"

module Kioku
  class Cli
    # `contextctl pair`: writes the host installation's bridge credential,
    # approved roots and project bindings.
    #
    # Pairing is an operator action, never something a hook or a model can do.
    # The file is written 0600 under KIOKU_HOME so the credential never lands in
    # a plugin installation directory or a repository.
    class Pair
      def initialize(config:, stdout: $stdout)
        @config = config
        @stdout = stdout
      end

      def run(argv)
        options = parse(argv)
        return usage if options[:help]

        document = merge(load_existing, options)
        write(document)
        @stdout.puts("paired: #{@config.config_path}")
        @stdout.puts("roots: #{document['approved_roots'].length}, projects: #{document['projects'].length}")
        0
      rescue Kioku::Error => e
        @stdout.puts("pair failed: #{e.message}")
        1
      end

      private

      def parse(argv)
        options = { roots: [], projects: {} }
        argv.each_with_index do |token, index|
          value = argv[index + 1]
          case token
          when "--token" then options[:token] = value
          when "--api-url" then options[:api_url] = value
          when "--root" then options[:roots] << value
          when "--project" then add_project(options, value)
          when "--help", "-h" then options[:help] = true
          end
        end
        options
      end

      # --project KEY=PATH binds a registered project key to an approved root.
      # An unbound root stays unresolved rather than defaulting anywhere.
      def add_project(options, value)
        key, path = value.to_s.split("=", 2)
        raise Kioku.invalid_request("--project expects KEY=PATH") if key.nil? || path.nil?

        resolved = File.realpath(File.expand_path(path))
        options[:projects][resolved] = key
        options[:roots] << resolved
      rescue SystemCallError
        raise Kioku.invalid_request("--project path does not exist: #{path}")
      end

      def load_existing
        Kioku::Config.read_file(@config.config_path)
      end

      def merge(existing, options)
        {
          "api_url" => options[:api_url] || existing["api_url"] || @config.api_url,
          "bridge_token" => options[:token] || existing["bridge_token"],
          "installation_id" => existing["installation_id"] || Kioku::Ids.uuid7,
          "approved_roots" => (Array(existing["approved_roots"]) + options[:roots]).compact.uniq,
          "projects" => (existing["projects"] || {}).merge(options[:projects])
        }
      end

      def write(document)
        FileUtils.mkdir_p(File.dirname(@config.config_path), mode: 0o700)
        File.open(@config.config_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.pretty_generate(document))
        end
      end

      def usage
        @stdout.puts(<<~TEXT)
          contextctl pair --token TOKEN [--api-url URL] [--root PATH] [--project KEY=PATH]

          Writes #{@config.config_path} with mode 0600. --project binds a registered
          project key to an approved root; a root with no binding stays unresolved.
        TEXT
        0
      end
    end
  end
end
