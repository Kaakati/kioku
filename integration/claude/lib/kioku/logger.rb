# frozen_string_literal: true

require "json"
require "time"

module Kioku
  # Diagnostics only, and always on stderr. Both protocol surfaces this package
  # speaks -- the Claude hook protocol and MCP over stdio -- reserve stdout, so
  # a stray print there corrupts the session. Nothing in this class may ever
  # write to stdout.
  class Logger
    LEVELS = { "debug" => 0, "info" => 1, "warn" => 2, "error" => 3 }.freeze
    REDACTED_KEYS = %w[token bridge_token password secret authorization body content prompt].freeze

    def initialize(component:, io: $stderr, level: ENV.fetch("KIOKU_LOG_LEVEL", "warn"))
      @component = component
      @io = io
      @threshold = LEVELS.fetch(level.to_s.downcase, 2)
    end

    LEVELS.each_key do |name|
      define_method(name) { |message, **fields| emit(name, message, fields) }
    end

    private

    def emit(level, message, fields)
      return if LEVELS.fetch(level) < @threshold

      line = {
        "ts" => Time.now.utc.iso8601(3),
        "level" => level,
        "component" => @component,
        "message" => message
      }.merge(redact(fields))
      @io.puts(JSON.generate(line))
      @io.flush
    rescue IOError, Errno::EPIPE
      nil
    end

    def redact(fields)
      fields.each_with_object({}) do |(key, value), out|
        name = key.to_s
        out[name] = REDACTED_KEYS.include?(name) ? "[redacted]" : value
      end
    end
  end
end
