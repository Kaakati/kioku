# frozen_string_literal: true

require "json"

module Kioku
  # Length-prefixed JSON framing used on the agent's Unix socket and inside the
  # body of the agent-initiated control connection.
  #
  #   KIOKU/1 <decimal byte length>\n<exactly that many bytes of UTF-8 JSON>
  #
  # The explicit length means a reader rejects an oversized frame from the
  # header alone, before allocating for it, and never has to scan a partially
  # received body for a delimiter.
  module Frame
    MAX_BYTES = 8 * 1024 * 1024
    HEADER_LIMIT = 64
    HEADER_PATTERN = /\A#{Regexp.escape(Kioku::FRAME_PROTOCOL)} (\d{1,9})\z/

    module_function

    def write(io, object)
      body = JSON.generate(object).b
      raise too_large(body.bytesize, MAX_BYTES) if body.bytesize > MAX_BYTES

      io.write("#{Kioku::FRAME_PROTOCOL} #{body.bytesize}\n")
      io.write(body)
      io.flush
      body.bytesize
    end

    # Returns nil at a clean end of stream.
    def read(io, max_bytes: MAX_BYTES)
      header = io.gets("\n", HEADER_LIMIT)
      return nil if header.nil?

      length = parse_header(header, max_bytes)
      body = io.read(length)
      raise truncated(length, body ? body.bytesize : 0) if body.nil? || body.bytesize < length

      decode(body)
    end

    def parse_header(header, max_bytes)
      match = HEADER_PATTERN.match(header.chomp)
      raise malformed(header) if match.nil?

      length = match[1].to_i
      raise too_large(length, max_bytes) if length > max_bytes

      length
    end

    def decode(body)
      parsed = JSON.parse(body.force_encoding(Encoding::UTF_8))
      raise Kioku.invalid_request("frame body must be a JSON object") unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise Kioku.invalid_request("frame body is not valid JSON")
    end

    def malformed(header)
      Kioku.invalid_request(
        "malformed frame header",
        { "expected" => "#{Kioku::FRAME_PROTOCOL} <length>", "received_bytes" => header.bytesize }
      )
    end

    def too_large(length, max_bytes)
      Kioku::Error.new(
        "kioku.quota_exhausted",
        "frame exceeds the bounded frame size",
        details: { "quota_kind" => "frame_bytes", "limit" => max_bytes, "observed" => length }
      )
    end

    def truncated(expected, received)
      Kioku::TransportUnavailable.new("frame", "stream closed after #{received} of #{expected} bytes")
    end
  end
end
