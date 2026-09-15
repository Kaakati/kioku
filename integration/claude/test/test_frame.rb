# frozen_string_literal: true

require_relative "test_helper"
require "kioku/frame_buffer"

class TestFrame < Minitest::Test
  def roundtrip(object)
    io = StringIO.new(+"", "w+")
    Kioku::Frame.write(io, object)
    io.rewind
    Kioku::Frame.read(io)
  end

  def test_writes_and_reads_one_frame
    assert_equal({ "op" => "agent.health", "payload" => { "a" => 1 } },
                 roundtrip({ "op" => "agent.health", "payload" => { "a" => 1 } }))
  end

  def test_header_declares_the_body_length
    io = StringIO.new(+"", "w+")
    Kioku::Frame.write(io, { "op" => "ping" })
    assert_match(/\AKIOKU\/1 \d+\n/, io.string)
  end

  def test_end_of_stream_reads_as_nil
    assert_nil Kioku::Frame.read(StringIO.new(""))
  end

  def test_a_malformed_header_is_rejected
    error = assert_raises(Kioku::Error) { Kioku::Frame.read(StringIO.new("GET / HTTP/1.1\n{}")) }
    assert_equal "kioku.invalid_request", error.code
  end

  # The declared length is refused before the body is allocated for.
  def test_an_oversized_declared_length_is_refused_from_the_header_alone
    error = assert_raises(Kioku::Error) { Kioku::Frame.read(StringIO.new("KIOKU/1 999999999\n")) }
    assert_equal "kioku.quota_exhausted", error.code
    assert_equal "frame_bytes", error.details["quota_kind"]
  end

  def test_a_truncated_body_is_a_transport_failure_not_a_partial_result
    error = assert_raises(Kioku::TransportUnavailable) { Kioku::Frame.read(StringIO.new("KIOKU/1 40\n{\"op\"")) }
    assert_equal "kioku.internal_error", error.code
  end

  def test_frame_buffer_reassembles_frames_split_across_chunks
    io = StringIO.new(+"", "w+")
    Kioku::Frame.write(io, { "type" => "request", "id" => "1" })
    Kioku::Frame.write(io, { "type" => "cancel", "id" => "1" })
    bytes = io.string

    buffer = Kioku::FrameBuffer.new
    frames = []
    bytes.each_char.each_slice(7) do |chunk|
      buffer << chunk.join
      buffer.each_frame { |frame| frames << frame }
    end

    assert_equal %w[request cancel], frames.map { |frame| frame["type"] }
  end

  def test_frame_buffer_returns_nil_until_a_frame_is_complete
    buffer = Kioku::FrameBuffer.new
    buffer << "KIOKU/1 13\n{\"a\":"
    assert_nil buffer.shift
    buffer << "1234567}"
    assert_equal({ "a" => 1_234_567 }, buffer.shift)
  end
end
