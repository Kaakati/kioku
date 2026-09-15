# frozen_string_literal: true

require "json"

module Kioku
  # Bounded stdin decoding for the hook path. A hook payload is read under both
  # a byte ceiling and a wall-clock ceiling: an oversized or slow producer must
  # fail visibly and cheaply rather than growing a String until the hook's own
  # timeout kills the process mid-write.
  module BoundedIO
    DEFAULT_LIMIT_BYTES = 1_048_576
    CHUNK_BYTES = 16_384

    module_function

    def read_json(io, limit: DEFAULT_LIMIT_BYTES, timeout_ms: nil)
      raw = read_bounded(io, limit: limit, timeout_ms: timeout_ms)
      parse_object(raw)
    end

    def read_bounded(io, limit: DEFAULT_LIMIT_BYTES, timeout_ms: nil)
      deadline = timeout_ms && (now + (timeout_ms / 1000.0))
      buffer = +""
      loop do
        wait_readable!(io, deadline)
        chunk = next_chunk(io)
        break if chunk.nil?

        buffer << chunk
        raise oversize(limit) if buffer.bytesize > limit
      end
      buffer
    end

    def next_chunk(io)
      io.readpartial(CHUNK_BYTES)
    rescue EOFError
      nil
    end

    def wait_readable!(io, deadline)
      return if deadline.nil?
      return unless io.is_a?(::IO)

      remaining = deadline - now
      raise timed_out if remaining <= 0
      return if ::IO.select([io], nil, nil, remaining)

      raise timed_out
    end

    def parse_object(raw)
      raise Kioku.invalid_request("empty payload") if raw.nil? || raw.strip.empty?

      parsed = JSON.parse(raw)
      raise Kioku.invalid_request("payload must be a JSON object") unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise Kioku.invalid_request("payload is not valid JSON", { "parser" => e.class.name })
    end

    def oversize(limit)
      Kioku.invalid_request("payload exceeded the bounded input limit", { "limit_bytes" => limit })
    end

    def timed_out
      Kioku::Error.new("kioku.deadline_exceeded", "bounded input did not arrive before the deadline")
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
