# frozen_string_literal: true

require_relative "test_helper"

class TestBoundedIO < Minitest::Test
  def test_reads_a_json_object
    io = StringIO.new('{"hook_event_name":"Stop"}')
    assert_equal({ "hook_event_name" => "Stop" }, Kioku::BoundedIO.read_json(io))
  end

  def test_rejects_a_payload_over_the_limit
    io = StringIO.new("x" * 5_000)
    error = assert_raises(Kioku::Error) { Kioku::BoundedIO.read_json(io, limit: 1_024) }
    assert_equal "kioku.invalid_request", error.code
    assert_equal 1_024, error.details["limit_bytes"]
  end

  def test_accepts_a_payload_exactly_at_the_limit
    body = JSON.generate({ "hook_event_name" => "Stop" })
    parsed = Kioku::BoundedIO.read_json(StringIO.new(body), limit: body.bytesize)
    assert_equal "Stop", parsed["hook_event_name"]
  end

  def test_rejects_malformed_json
    error = assert_raises(Kioku::Error) { Kioku::BoundedIO.read_json(StringIO.new("{oops")) }
    assert_equal "kioku.invalid_request", error.code
  end

  def test_rejects_a_non_object_payload
    error = assert_raises(Kioku::Error) { Kioku::BoundedIO.read_json(StringIO.new("[1,2]")) }
    assert_equal "kioku.invalid_request", error.code
  end

  def test_rejects_empty_input
    error = assert_raises(Kioku::Error) { Kioku::BoundedIO.read_json(StringIO.new("   ")) }
    assert_equal "kioku.invalid_request", error.code
  end

  # A pipe that never delivers must not hold the hook open past its budget.
  def test_times_out_on_a_stalled_pipe
    reader, writer = IO.pipe
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Kioku::Error) { Kioku::BoundedIO.read_json(reader, timeout_ms: 120) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal "kioku.deadline_exceeded", error.code
    assert_operator elapsed, :<, 2.0
  ensure
    reader&.close
    writer&.close
  end

  def test_reads_from_a_real_pipe
    reader, writer = IO.pipe
    writer.write('{"hook_event_name":"UserPromptSubmit"}')
    writer.close
    parsed = Kioku::BoundedIO.read_json(reader, timeout_ms: 2_000)
    assert_equal "UserPromptSubmit", parsed["hook_event_name"]
  ensure
    reader&.close
  end
end
