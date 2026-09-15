# frozen_string_literal: true

module Kioku
  # Diagnostics go to stderr, never to stdout.
  #
  # "context-mcp | ... | stdout is reserved for MCP"; "contextctl | ... | stdout is
  # event-specific output; diagnostics use stderr" [plan §3 trust-boundary table]. One
  # leaked log line corrupts a JSON-RPC stream or a hook's event output, so nothing here
  # can be pointed at stdout by configuration.
  class Logger
    LEVELS = %w[debug info warn error].freeze
    DEFAULT_LEVEL = "warn"

    def initialize(program:, stream: $stderr, level: ENV.fetch("KIOKU_LOG_LEVEL", DEFAULT_LEVEL))
      @program = program
      @stream = stream
      @threshold = LEVELS.index(level.to_s.downcase) || LEVELS.index(DEFAULT_LEVEL)
    end

    LEVELS.each_with_index do |level, index|
      define_method(level) { |message| write(level, index, message) }
    end

    private

    def write(level, index, message)
      return if index < @threshold

      @stream.write("#{level.upcase} [#{@program}] #{message}\n")
      @stream.flush
    rescue IOError, Errno::EPIPE, Errno::EBADF
      nil
    end
  end
end
