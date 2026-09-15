# frozen_string_literal: true

require "test_helper"
require_relative "contract_fixtures"

# D4 — an evidence ref is one of three keys, and one this build cannot resolve is
# not a malformed request.
#
# `common.schema.json#/$defs/evidence_ref` declares a closed object carrying
# exactly one of evidence_key, object_key or event_key, and the context_remember
# response shape already carries the machinery for the unimplemented case:
# `evidence_rejected: [{ref, reason: enum(scope_mismatch|unavailable|deleted|
# anchor_invalid|not_found)}]`. Only an EMPTY eligible set fails the write, with
# kioku.evidence_required.
#
# Today `Remember#stage` refuses anything but object_key with
# invalid!("evidence.ref.object_key"), so a caller is told its request was
# malformed when the request was exactly what the contract names — the same class
# of dishonesty as reporting a core 500 as a client error.
class EvidenceRefConformanceTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport

  Fixtures = Kioku::Test::ContractFixtures

  DURABLE = Kioku::Test::Factories::DURABLE_OBJECT_KEY
  MISSING = Kioku::Test::Factories::MISSING_OBJECT_KEY

  setup do
    arrange_project_with_durable_evidence
  end

  test "should declare exactly the three evidence reference keys the shared schema names" do
    ref = Fixtures.artifact("common.schema.json").dig("$defs", "evidence_ref")

    assert_equal %w[evidence_key object_key event_key].sort, ref.fetch("properties").keys.sort
    assert_equal 1, ref.fetch("maxProperties")
  end

  # The write commits on the eligible link, and the ref this build cannot resolve
  # is reported per entry rather than refusing the whole request.
  test "should commit the eligible link and report an unresolvable reference when both are supplied" do
    evidence = [{ ref: { object_key: DURABLE }, relation: :supports },
                { ref: { evidence_key: "ev-not-in-this-build" }, relation: :context }]

    result = remember_service.call(**remember_arguments(evidence: evidence))

    assert_predicate result, :saved?
    assert_equal [DURABLE], result.evidence_accepted.map { |entry| entry[:ref][:object_key] }
    assert_equal ["ev-not-in-this-build"],
                 result.evidence_rejected.map { |entry| entry[:ref][:evidence_key] }
  end

  # The reason is named from the contract's own enum, so a caller learns why the
  # link was not eligible instead of being told to fix a well-formed request.
  # `not_found` is the reason the shared case an_evidence_key_ref_is_a_valid_shape
  # declares for a reference this build has no resolver for.
  test "should name a declared rejection reason for every reference it could not resolve" do
    evidence = [{ ref: { object_key: DURABLE }, relation: :supports },
                { ref: { event_key: "event-not-in-this-build" }, relation: :context }]

    result = remember_service.call(**remember_arguments(evidence: evidence))

    assert_equal %w[not_found], result.evidence_rejected.map { |entry| entry[:reason].to_s }
  end

  # The companion, and the thing that stops D4 being "resolved" by accepting every
  # ref: eligibility still decides whether the write commits at all, and an empty
  # eligible set is kioku.evidence_required rather than kioku.invalid_request. A
  # caller branches on the two differently — add evidence, or fix the request.
  test "should refuse the write with evidence required when no supplied reference is eligible" do
    evidence = [{ ref: { evidence_key: "ev-not-in-this-build" }, relation: :supports }]

    result = remember_service.call(**remember_arguments(evidence: evidence))

    refute_predicate result, :saved?
    assert_equal "kioku.evidence_required", result.error_code
    assert_equal 0, memory_revision_count
  end

  # Unavailable bytes and an unresolvable handle are different reasons, and
  # collapsing them would tell an operator to look in the wrong place.
  test "should keep reporting unavailable bytes as unavailable rather than as not found" do
    evidence = [{ ref: { object_key: DURABLE }, relation: :supports },
                { ref: { object_key: MISSING }, relation: :contradicts }]

    result = remember_service.call(**remember_arguments(evidence: evidence))

    assert_equal %w[unavailable], result.evidence_rejected.map { |entry| entry[:reason].to_s }
  end

  # Two keys in one ref stays kioku.invalid_request: it is genuinely ambiguous and
  # the core would have to guess which reference the caller meant.
  test "should refuse the write as invalid when one reference names two keys" do
    evidence = [{ ref: { object_key: DURABLE, event_key: "event-1" }, relation: :supports }]

    result = remember_service.call(**remember_arguments(evidence: evidence))

    refute_predicate result, :saved?
    assert_equal "kioku.invalid_request", result.error_code
  end

  test "should refuse the write as invalid when a reference names nothing at all" do
    result = remember_service.call(**remember_arguments(evidence: [{ ref: {}, relation: :supports }]))

    refute_predicate result, :saved?
    assert_equal "kioku.invalid_request", result.error_code
  end
end
