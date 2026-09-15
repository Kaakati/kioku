# frozen_string_literal: true

require_relative "../test_helper"
require_relative "contract_fixtures"
require_relative "contract_assertions"
require "kioku/envelope"

# Request-envelope conformance, host side.
#
# Every case in contracts/v1/conformance/envelope_request_cases.json is driven
# through the host's REAL parser, Kioku::Envelope::RequestParser. The core runs the
# identical case list through Context::Contracts::EnvelopeDecoder, so a divergence
# between the two halves fails on whichever side diverged rather than staying
# invisible because neither side ever sees the other's payloads.
class ContractEnvelopeRequestTest < Minitest::Test
  include Kioku::TestSupport::ContractAssertions

  Fixtures = Kioku::TestSupport::ContractFixtures

  def test_should_reach_the_declared_outcome_and_wire_code_for_every_shared_envelope_case
    each_case(Fixtures.request_cases.fetch("cases"), side: "host") do |kase|
      assert_outcome(kase.fetch("expect"), kase.fetch("id")) { parse(kase) }
    end
  end

  def test_should_name_the_field_the_contract_declares_for_every_refused_envelope_case
    each_case(Fixtures.request_cases.fetch("cases"), side: "host") do |kase|
      expect = kase.fetch("expect")
      next if expect.fetch("outcome") == "accepted"

      error = begin
        parse(kase)
        nil
      rescue Kioku::Error => e
        e
      end
      assert_refusal_detail(expect, error, kase.fetch("id")) unless error.nil?
    end
  end

  # The closure rule (D6), stated on its own so its failure is diagnostic rather
  # than one line in a list. A name blacklist checked at one depth is bypassed by
  # nesting the name one level deeper; the artifact's answer is that every request
  # object is closed, so `authority` is refused inside `correlation` and `priority`
  # — which no blacklist would ever carry — is refused too.
  def test_should_refuse_an_undeclared_envelope_key_at_every_depth_the_artifact_closes
    smuggled = {
      "/envelope/priority" => { "priority" => "high" },
      "/envelope/authority" => { "authority" => "user" },
      "/envelope/correlation/origin_role" => { "correlation" => { "session_id" => "s-1", "origin_role" => "user" } },
      "/envelope/scope/authority" => { "scope" => { "store" => "global", "authority" => "user" } }
    }

    accepted = smuggled.reject do |_, patch|
      begin
        Kioku::Envelope.parse_request(read_envelope.merge(patch))
        false
      rescue Kioku::Error
        true
      end
    end

    assert_empty accepted.keys, "these undeclared keys reached the parser unrefused"
  end

  # The companion. Closure is only meaningful if the declared keys still pass; a
  # parser that refuses every correlation object would satisfy the case above.
  def test_should_accept_every_correlation_hint_the_shared_schema_declares
    declared = Fixtures.artifact("common.schema.json").dig("$defs", "correlation", "properties").keys
    correlation = declared.to_h { |name| [name, "hint-#{name}"] }

    parsed = Kioku::Envelope.parse_request(read_envelope.merge("correlation" => correlation))

    assert_equal "kioku", parsed.scope.project_key
  end

  # D3. The pattern is the artifact's, so relaxing request_id in either Ruby
  # transcription cannot make this pass.
  def test_should_refuse_a_request_id_that_does_not_match_the_declared_uuid_v7_pattern
    pattern = Regexp.new(Fixtures.artifact("common.schema.json").dig("$defs", "request_id", "pattern"))
    offenders = [
      "9f8b2d41-3c6e-4a17-8d52-0b7e1c9a4f36",  # UUIDv4
      "018F3A2B-7C1D-7E4A-9B2C-3D4E5F6A7B8C",  # uppercase
      "018f3a2b-7c1d-7e4a-9b2c-3d4e5f6a7b8cd" # 37 characters
    ]
    refute offenders.any? { |id| pattern.match?(id) }, "a fixture id matches the declared pattern"

    accepted = offenders.reject do |id|
      begin
        Kioku::Envelope.parse_request(read_envelope.merge("request_id" => id))
        false
      rescue Kioku::Error
        true
      end
    end

    assert_empty accepted, "these request_id values were accepted despite failing the declared pattern"
  end

  # D2. The major decides; any minor is accepted, because minor additions are
  # additive-only and exact equality would make every additive release breaking.
  def test_should_accept_any_minor_of_the_supported_major_and_refuse_another_major
    pattern = Regexp.new(Fixtures.artifact("common.schema.json").dig("$defs", "schema_version", "pattern"))
    accepted = %w[kioku.tool.v1 kioku.tool.v1.0 kioku.tool.v1.7 kioku.tool.v1.412]
    assert accepted.all? { |version| pattern.match?(version) }

    accepted.each do |version|
      parsed = Kioku::Envelope.parse_request(read_envelope.merge("schema_version" => version))
      assert_equal 1, parsed.schema_major, "#{version} was not matched on its major"
    end

    error = assert_raises(Kioku::Error) do
      Kioku::Envelope.parse_request(read_envelope.merge("schema_version" => "kioku.tool.v2"))
    end
    assert_equal "kioku.unsupported_schema_version", error.code
  end

  private

  def parse(kase)
    Kioku::Envelope.parse_request(Fixtures.request_envelope_for(kase),
                                  mutation: kase.fetch("operation") == "mutation")
  end

  def read_envelope
    Fixtures.request_cases.fetch("base_envelopes").fetch("read")
  end
end
