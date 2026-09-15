# frozen_string_literal: true

require "json"

module Kioku
  # Incremental reader for the KIOKU/1 framing over a stream whose chunk
  # boundaries the reader does not control -- notably the response body of the
  # agent-initiated control connection. Bytes are appended as they arrive and
  # complete frames are taken off the front.
  class FrameBuffer
    def initialize(max_bytes: Kioku::Frame::MAX_BYTES)
      @max_bytes = max_bytes
      @buffer = +"".b
      @needed = nil
    end

    def <<(bytes)
      @buffer << bytes.b
      self
    end

    # Returns the next complete frame, or nil when more bytes are needed.
    def shift
      read_header if @needed.nil?
      return nil if @needed.nil? || @buffer.bytesize < @needed

      body = @buffer.slice!(0, @needed)
      @needed = nil
      Kioku::Frame.decode(body)
    end

    def each_frame
      while (frame = shift)
        yield frame
      end
    end

    private

    def read_header
      index = @buffer.index("\n")
      if index.nil?
        raise header_overflow if @buffer.bytesize > Kioku::Frame::HEADER_LIMIT

        return nil
      end

      header = @buffer.slice!(0, index + 1)
      @needed = Kioku::Frame.parse_header(header, @max_bytes)
    end

    def header_overflow
      Kioku.invalid_request(
        "no frame header within the header limit",
        { "limit_bytes" => Kioku::Frame::HEADER_LIMIT }
      )
    end
  end
end
