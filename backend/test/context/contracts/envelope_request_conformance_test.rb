# frozen_string_literal: true

require "test_helper"
require_relative "contract_fixtures"

# Request-envelope conformance, core side.
#
# Every case in conformance/envelope_request_cases.json is driven through the
# core's REAL decoder, Context::Contracts::EnvelopeDecoder. The host suite drives
# the identical case list through Kioku::Envelope::RequestParser, so a divergence
# between the two halves fails on whichever side diverged instead of staying
# invisible because the two have never exchanged an envelope.
class EnvelopeRequestConformanceTest < ActiveSupport::TestCase
  include Kioku::Test::ContractAssertions

  Fixtures = Kioku::Test::ContractFixtures

  test "should reach the declared outcome and wire code for every shared envelope case" do
    each_case(Fixtures.request_cases.fetch("cases"), side: "core") do |kase|
      assert_outcome(kase.fetch("expect"), kase.fetch("id")) { decode(kase) }
    end
  end

  test "should name the field the contract declares for every refused envelope case" do
    each_case(Fixtures.request_cases.fetch("cases"), side: "core") do |kase|
      expect = kase.fetch("expect")
      next if expect.fetch("outcome") == "accepted"

      error = refusal_from { decode(kase) }
      assert_refusal_detail(expect, error, kase.fetch("id")) unless error.nil?
    end
  end

  # D2. "Rejected with kioku.unsupported_schema_version if the major does not match
  # a supported contract. Minor additions are additive-only." Exact string equality
  # with "kioku.tool.v1" turns every additive minor release into a breaking one.
  test "should accept any minor of the supported major when a schema version is decoded" do
    pattern = Regexp.new(Fixtures.artifact("common.schema.json").dig("$defs", "schema_version", "pattern"))
    minors = %w[kioku.tool.v1 kioku.tool.v1.0 kioku.tool.v1.7 kioku.tool.v1.412]
    assert minors.all? { |version| pattern.match?(version) }, "a fixture version is not contract-shaped"

    refused = minors.reject { |version| decode_read("schema_version" => version) }

    assert_empty refused, "these accepted minors of the supported major were refused"
  end

  # The companion. Accepting an unknown minor must not become accepting anything,
  # and the major mismatch is reported before any scope work, which is what lets
  # that response carry a null generation vector honestly.
  test "should refuse another major with unsupported schema version when a request is decoded" do
    error = assert_raises(Context::Errors::Error) { decode_read!("schema_version" => "kioku.tool.v2") }

    assert_equal "kioku.unsupported_schema_version", error.wire_code
  end

  # D2's second half. An unknown minor does not widen the accepted surface: a field
  # a later minor adds is still refused by name, so a caller learns the version was
  # fine and this particular field is not taken yet.
  test "should still refuse an undeclared field when the declared minor is unknown" do
    error = assert_raises(Context::Errors::Error) do
      decode_read!("schema_version" => "kioku.tool.v1.7", "priority" => "high")
    end

    assert_equal "kioku.invalid_request", error.wire_code,
                 "an unknown minor must be accepted and the undeclared field refused by name"
  end

  # D3. The pattern is the artifact's, so relaxing request_id in either Ruby
  # transcription cannot make this pass.
  test "should refuse a request id that does not match the declared uuid v7 pattern" do
    accepted = malformed_request_ids.select { |id| decode_read("request_id" => id) }

    assert_empty accepted, "these request_id values were accepted despite failing the declared pattern"
  end

  # D3, and the reason it is not merely pedantry: every request_id the backend
  # suite exercises comes from Kioku::Test::Factories, which emits
  # SecureRandom.uuid — a v4 — so every payload this suite proves correct would be
  # refused by the host that sends them.
  test "should exercise only request ids the shared contract accepts in this suite's own factories" do
    pattern = Regexp.new(Fixtures.artifact("common.schema.json").dig("$defs", "request_id", "pattern"))
    exercised = {
      "wire_envelope" => wire_envelope["request_id"],
      "wire_read_envelope" => wire_read_envelope["request_id"],
      "mutation_envelope" => mutation_envelope.request_id
    }

    offending = exercised.reject { |_, id| pattern.match?(id.to_s) }

    assert_empty offending, "these factories emit a request_id the host would refuse"
  end

  # D6. A name blacklist checked at one depth is bypassed by nesting the name one
  # level deeper, which is the observed defect: BaseController checks seven names at
  # body top level, so {"envelope":{"authority":"user"}} passes. Closure refuses the
  # name wherever it appears, and refuses `priority` too — a name no blacklist would
  # ever carry.
  test "should refuse an undeclared envelope key at every depth the artifact closes" do
    smuggled = {
      "/envelope/priority" => { "priority" => "high" },
      "/envelope/authority" => { "authority" => "user" },
      "/envelope/correlation/origin_role" => { "correlation" => { "session_id" => "s-1",
                                                                  "origin_role" => "user" } },
      "/envelope/scope/authority" => { "scope" => { "store" => "global", "authority" => "user" } }
    }

    accepted = smuggled.select { |_, patch| decode_read(patch) }

    assert_empty accepted.keys, "these undeclared keys reached the decoder unrefused"
  end

  # The companion. Closure only means something if the declared keys still pass; a
  # decoder that refused every correlation object would satisfy the case above.
  test "should accept every correlation hint the shared schema declares" do
    declared = Fixtures.artifact("common.schema.json").dig("$defs", "correlation", "properties").keys
    correlation = declared.index_with { |name| "hint-#{name}" }

    envelope = Context::Contracts::EnvelopeDecoder.new(operation: :read)
                                                  .call(read_wire.merge("correlation" => correlation))

    assert_equal "kioku", envelope.scope.project_key
  end

  private

  def decode(kase)
    Context::Contracts::EnvelopeDecoder
      .new(operation: kase.fetch("operation").to_sym)
      .call(Fixtures.request_envelope_for(kase))
  end

  # Returns the decoded envelope, or nil when the decoder refused it.
  def decode_read(overrides)
    decode_read!(overrides)
  rescue Context::Errors::Error
    nil
  end

  def decode_read!(overrides)
    Context::Contracts::EnvelopeDecoder.new(operation: :read).call(read_wire.merge(overrides))
  end

  def read_wire
    Fixtures.request_cases.fetch("base_envelopes").fetch("read")
  end

  def malformed_request_ids
    ["9f8b2d41-3c6e-4a17-8d52-0b7e1c9a4f36",   # UUIDv4
     "018F3A2B-7C1D-7E4A-9B2C-3D4E5F6A7B8C",   # uppercase
     "018f3a2b-7c1d-7e4a-9b2c-3d4e5f6a7b8cd",  # 37 characters
     "not-a-uuid-at-all"]
  end

  def refusal_from
    yield
    nil
  rescue Context::Errors::Error => e
    e
  end
end
