# frozen_string_literal: true

module Kioku
  module TestSupport
    # Speaks real JSON-RPC 2.0 over the real stdio of a spawned host entry point.
    #
    # The MCP stdio transport is newline-delimited JSON on stdout
    # [plan §3 "context-mcp ... stdout is reserved for MCP"; research §11].
    class StdioServer
      DEFAULT_TIMEOUT = 5.0

      attr_reader :raw_stdout_lines

      def self.binary_path(name)
        File.join(KIOKU_PACKAGE_ROOT, "bin", name)
      end

      def self.require_binary!(name)
        path = binary_path(name)
        return path if File.file?(path)

        raise HostBinaryMissing,
              "host entry point #{path} does not exist; the host package is not implemented"
      end

      # Every spawned entry point points at a socket path that cannot exist, so no
      # test can silently reach a real agent. Tests override it deliberately.
      def self.process_env(overrides = {})
        absent = File.join(Dir.tmpdir, "kioku-absent-#{Process.pid}-#{SecureRandom.hex(4)}", "agent.sock")
        env = { "KIOKU_SOCKET_PATH" => absent }
        gemfile = File.join(KIOKU_PACKAGE_ROOT, "Gemfile")
        env["BUNDLE_GEMFILE"] = gemfile if File.file?(gemfile)
        env.merge(overrides.transform_keys(&:to_s))
      end

      def initialize(name, env: {})
        path = self.class.require_binary!(name)
        @stdin, @stdout, @stderr, @wait =
          Open3.popen3(self.class.process_env(env), RbConfig.ruby, path)
        @buffer = +""
        @raw_stdout_lines = []
        @stderr_buffer = +""
        @stderr_lock = Mutex.new
        @stderr_thread = Thread.new { drain_stderr }
        @next_id = 0
      end

      def handshake(timeout: DEFAULT_TIMEOUT)
        request("initialize", {
                  "protocolVersion" => "2025-06-18",
                  "capabilities" => {},
                  "clientInfo" => { "name" => "kioku-red-suite", "version" => "0.0.0" }
                }, timeout: timeout)
        notify("notifications/initialized")
        self
      end

      def tools(timeout: DEFAULT_TIMEOUT)
        request("tools/list", {}, timeout: timeout).dig("result", "tools")
      end

      def call_tool(name, arguments, timeout: DEFAULT_TIMEOUT)
        request("tools/call", { "name" => name, "arguments" => arguments }, timeout: timeout)
      end

      def request(method, params = nil, timeout: DEFAULT_TIMEOUT)
        id = (@next_id += 1)
        message = { "jsonrpc" => "2.0", "id" => id, "method" => method }
        message["params"] = params unless params.nil?
        write(message)
        await(id, timeout)
      end

      def notify(method, params = nil)
        message = { "jsonrpc" => "2.0", "method" => method }
        message["params"] = params unless params.nil?
        write(message)
      end

      def write_raw(text)
        @stdin.write("#{text}\n")
        @stdin.flush
      end

      def stderr_text
        @stderr_lock.synchronize { @stderr_buffer.dup }
      end

      def alive?
        @wait.alive?
      end

      def close
        @stdin.close unless @stdin.closed?
      rescue IOError, Errno::EPIPE
        nil
      ensure
        terminate
      end

      private

      def write(message)
        @stdin.write("#{JSON.generate(message)}\n")
        @stdin.flush
      end

      def await(id, timeout)
        deadline = Clock.monotonic + timeout
        loop do
          line = read_line([deadline - Clock.monotonic, 0.01].max)
          next if line.strip.empty?

          message = parse_protocol_line(line)
          return message if message["id"] == id
        end
      end

      def parse_protocol_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        raise ProtocolImpurity,
              "non-protocol text on stdout: #{line.inspect} (stderr: #{stderr_text[0, 400].inspect})"
      end

      def read_line(timeout)
        deadline = Clock.monotonic + timeout
        loop do
          if (index = @buffer.index("\n"))
            line = @buffer.slice!(0..index)
            @raw_stdout_lines << line
            return line
          end
          fill_buffer(deadline)
        end
      end

      def fill_buffer(deadline)
        remaining = deadline - Clock.monotonic
        raise ProtocolTimeout, "no stdout line before deadline (stderr: #{stderr_text[0, 400].inspect})" if remaining <= 0

        raise ProtocolTimeout, "stdout blocked (stderr: #{stderr_text[0, 400].inspect})" unless IO.select([@stdout], nil, nil, remaining)

        @buffer << @stdout.read_nonblock(4096)
      rescue IO::WaitReadable
        retry
      rescue EOFError
        raise ProtocolTimeout, "server closed stdout (stderr: #{stderr_text[0, 400].inspect})"
      end

      # readpartial, not read(n): a short diagnostic must become visible immediately
      # rather than waiting for a full buffer.
      def drain_stderr
        loop do
          chunk = @stderr.readpartial(4096)
          @stderr_lock.synchronize { @stderr_buffer << chunk }
        end
      rescue EOFError, IOError, Errno::EIO, Errno::EBADF
        nil
      end

      def terminate
        Process.kill("KILL", @wait.pid) if @wait.alive?
      rescue Errno::ESRCH, Errno::EPERM, RangeError
        nil
      ensure
        @wait.join(2.0)
        @stderr_thread&.join(1.0)
      end
    end

    # Reads the Kioku response envelope back out of an MCP tool result.
    #
    # A refused call is rendered either as a JSON-RPC error carrying the wire name in
    # error.data.code, or as a tool result whose text content is the Kioku response
    # envelope carrying error.code. Both renderings are accepted; the wire name is not.
    module McpResult
      module_function

      def envelope(message)
        text = message.dig("result", "content", 0, "text")
        return nil if text.nil?

        begin
          JSON.parse(text)
        rescue JSON::ParserError
          nil
        end
      end

      def error_code(message)
        transport = message.dig("error", "data", "code")
        return transport if transport.is_a?(String)

        envelope(message)&.dig("error", "code")
      end

      def status(message)
        envelope(message)&.fetch("status", nil)
      end

      def refused?(message)
        !message["error"].nil? || message.dig("result", "isError") == true
      end
    end
  end
end
