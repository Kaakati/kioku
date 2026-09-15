# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../kioku/contract_fixtures"
require_relative "../kioku/contract_assertions"
require "kioku/mcp/dispatch"
require "kioku/request_digest"

# Tool-argument conformance, host side.
#
# Every case in contracts/v1/conformance/tool_input_cases.json is driven through
# the host's REAL validators, reached through the dispatch table the running server
# uses, so a case cannot be satisfied by a validator the adapter never calls.
#
# The cases carry the artifact's placeholder envelope.request_digest. A digest that
# does not describe its body is E1's defect, not a tool-argument question, so the
# harness asserts the digest a well-behaved caller would have computed and leaves
# the mismatch to contract_request_digest_test.rb.
class ContractToolInputTest < Minitest::Test
  include Kioku::TestSupport::ContractAssertions

  Fixtures = Kioku::TestSupport::ContractFixtures

  def test_should_reach_the_declared_outcome_and_wire_code_for_every_shared_tool_case
    each_case(Fixtures.tool_cases.fetch("cases"), side: "host") do |kase|
      assert_outcome(kase.fetch("expect"), kase.fetch("id")) { validate(kase) }
    end
  end

  def test_should_name_the_field_the_contract_declares_for_every_refused_tool_case
    each_case(Fixtures.tool_cases.fetch("cases"), side: "host") do |kase|
      expect = kase.fetch("expect")
      next if expect.fetch("outcome") == "accepted"

      error = begin
        validate(kase)
        nil
      rescue Kioku::Error => e
        e
      end
      assert_refusal_detail(expect, error, kase.fetch("id")) unless error.nil?
    end
  end

  # D7, the consequence worth naming on its own. The published envelope has always
  # accepted expected_revision, but with memory_key refused there was nothing for it
  # to apply to: appending a revision to an existing memory was unreachable through
  # the published surface, and kioku.revision_conflict could never be provoked.
  def test_should_let_a_caller_name_the_memory_that_expected_revision_applies_to
    envelope = mutation_envelope.merge("expected_revision" => 3)
    arguments = remember_body.merge("memory_key" => "mem-1", "envelope" => envelope)

    parsed = validate_arguments("context_remember", arguments)

    assert_equal 3, parsed.expected_revision
  end

  # The companion: naming an existing memory without declaring the revision you
  # observed is a blind append, so the pair is required together.
  def test_should_refuse_a_named_memory_that_declares_no_expected_revision
    arguments = remember_body.merge("memory_key" => "mem-1", "envelope" => mutation_envelope)

    error = assert_raises(Kioku::Error) { validate_arguments("context_remember", arguments) }

    assert_equal "kioku.invalid_request", error.code
    assert_names_field(error, "expected_revision", "memory_key without expected_revision")
  end

  # D7. `override` is the project-exception input CLAUDE.md's first implementation
  # slice needs. While implemented.json carries it false the honest answer is a
  # refusal that names it and says why, never kioku.invalid_request (which tells a
  # caller its request was malformed) and never silence (which would let a caller
  # believe an exception had been recorded).
  def test_should_refuse_an_unimplemented_contract_named_input_by_name_rather_than_as_unknown
    arguments = remember_body.merge(
      "envelope" => mutation_envelope,
      "override" => { "target_global_memory_key" => "glob-1", "target_revision" => 2,
                      "replacement_body" => "This project pins the template explicitly.",
                      "reason" => "Local exception to the shared preference.",
                      "authority_basis" => "user instruction in this project" }
    )

    error = assert_raises(Kioku::Error) { validate_arguments("context_remember", arguments) }

    assert_equal "kioku.unsupported_operation", error.code
    assert_equal "not_implemented_in_this_build", detail(error, "reason")
    assert_names_field(error, "override", "unimplemented override input")
  end

  # The companion to the case above. `not_implemented_in_this_build` must be
  # reserved for the properties implemented.json actually lists: answering it for
  # an implemented property would hide a working feature behind a refusal.
  def test_should_report_not_implemented_only_for_the_properties_the_build_state_lists
    declared = Fixtures.artifact("implemented.json")
                       .dig("tools", "context_remember", "properties")
                       .reject { |_, implemented| implemented }.keys
    published = Fixtures.resolved_tools.fetch("context_remember").fetch("properties").keys

    assert_empty(declared & published,
                 "these properties are published to the model and simultaneously declared unimplemented")
  end

  private

  def validate(kase)
    tool, arguments = Fixtures.tool_arguments_for(kase)
    validate_arguments(tool, arguments)
  end

  def validate_arguments(tool, arguments)
    Kioku::Mcp::Dispatch::VALIDATORS.fetch(tool).new.call(arguments: signed(arguments))
  end

  # What a caller that computed its own digest would have sent.
  def signed(arguments)
    return arguments unless arguments.fetch("envelope").key?("request_digest")

    Fixtures.with_asserted_digest(arguments, Kioku::RequestDigest.compute(arguments))
  end

  def remember_body
    Fixtures.tool_cases.fetch("base_bodies").fetch("remember_project").fetch("body")
  end

  def mutation_envelope
    Fixtures.tool_cases.fetch("base_envelopes").fetch("mutation")
  end
end
