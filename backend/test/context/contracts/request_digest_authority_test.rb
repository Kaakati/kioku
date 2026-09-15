# frozen_string_literal: true

require "test_helper"
require_relative "contract_fixtures"

# E1 — the request digest is recomputed, never trusted.
#
# `contract.json request_digest.authority`: "The core RECOMPUTES the digest over
# the received body and compares it to the asserted value. A caller-asserted digest
# never decides a durability claim."
#
# Today nothing recomputes anything. `Kioku::RequestDigest` implements the
# canonicalization correctly on the host and has no callers; the core has no
# implementation at all. Both sides check only that the string is sha256 and 64 hex
# characters, and `Remember#replay` then compares the caller's ASSERTED digest
# against the stored one — so a caller that reuses an idempotency key with a stale
# digest is told saved for content that was never written. A caller-asserted fact
# is deciding a durability claim.
class RequestDigestAuthorityTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport

  Fixtures = Kioku::Test::ContractFixtures

  ASSERTED = "sha256:#{'0123456789abcdef' * 4}"
  OTHER_ASSERTED = "sha256:#{'fedcba9876543210' * 4}"

  setup do
    arrange_project_with_durable_evidence
  end

  # The durability lie, stated as the caller observes it. The first write commits
  # body A; the second reuses the key and the same asserted digest but carries body
  # B. Today the asserted digests match, so replay reports the write as saved and
  # hands back a memory_key and revision — for content the core never stored.
  test "should refuse a reused idempotency key when the request content is not the content it committed" do
    commit_first(body: "Two workers claimed the same invoice lease.")

    result = remember_service.call(**arguments(body: "Something else entirely.", digest: ASSERTED))

    refute_predicate result, :saved?
    assert_equal "kioku.idempotency_conflict", result.error_code
  end

  # The over-correction guard. "saved was a lie" must be fixed by refusing the
  # claim, not by making the second call write the content it claimed: a reused
  # idempotency key with a different digest writes nothing, per errors.json
  # kioku.idempotency_conflict.
  test "should write no new revision when a reused idempotency key carries different content" do
    original = "Two workers claimed the same invoice lease."
    committed = commit_first(body: original)

    remember_service.call(**arguments(body: "Something else entirely.", digest: ASSERTED))

    assert_equal 1, memory_revision_count
    assert_equal original, revisions_for(committed.memory_key).first.body
  end

  # The other direction, and the one that proves the digest is COMPUTED rather than
  # merely compared. The content is identical, so this is the same request; only the
  # string the caller asserted differs. Today the assertion decides, so the core
  # raises kioku.idempotency_conflict for a request it has already committed and the
  # caller cannot learn its own outcome.
  test "should replay the prior receipt when the same content arrives under a different asserted digest" do
    body = "Two workers claimed the same invoice lease."
    first = commit_first(body: body)

    result = remember_service.call(**arguments(body: body, digest: OTHER_ASSERTED))

    assert_predicate result, :saved?
    assert_equal first.memory_key, result.memory_key
    assert_equal 1, memory_revision_count
  end

  # The companion that stops both cases above being satisfied by refusing every
  # second write. A different idempotency key is a different request and commits.
  test "should commit a second write when the same content arrives under a fresh idempotency key" do
    body = "Two workers claimed the same invoice lease."
    commit_first(body: body)

    result = remember_service.call(**arguments(body: body, digest: ASSERTED, key: "idem-second"))

    assert_predicate result, :saved?
    assert_equal 2, memory_revision_count
  end

  # The primitive the boundary needs and the core does not have. The identical
  # literal is pinned in the host suite over the identical artifact body, so two
  # independent canonicalizations cannot each be self-consistent and disagree.
  #
  # The fixture body carries the placeholder envelope.request_digest and the pinned
  # value is the digest of that body without it: a digest cannot be one of its own
  # inputs, or no recomputation could ever be compared against the asserted value.
  test "should compute the digest both deploy units pin for the shared canonical body" do
    assert_equal Fixtures::GOLDEN_REQUEST_DIGEST,
                 Context::Contracts::RequestDigest.compute(Fixtures.golden_digest_body)
  end

  test "should exclude every field the shared contract excludes from the digest input" do
    base = Fixtures.golden_digest_body
    baseline = Context::Contracts::RequestDigest.compute(base)

    differing = Fixtures.contract.fetch("request_digest").fetch("excluded_fields").reject do |field|
      envelope = base.fetch("envelope").merge(field => varied(base.dig("envelope", field)))
      Context::Contracts::RequestDigest.compute(base.merge("envelope" => envelope)) == baseline
    end

    assert_empty differing, "these declared-excluded fields still changed the digest"
  end

  # "the same payload in a different project is a different request" — the digest
  # input includes project_key, so one project's receipt can never answer another's.
  test "should compute a different digest for the same payload in another project" do
    base = Fixtures.golden_digest_body
    scope = base.dig("envelope", "scope").merge("project_key" => "another-project")
    elsewhere = base.merge("envelope" => base.fetch("envelope").merge("scope" => scope))

    refute_equal Context::Contracts::RequestDigest.compute(base),
                 Context::Contracts::RequestDigest.compute(elsewhere)
  end

  private

  def commit_first(body:)
    result = remember_service.call(**arguments(body: body, digest: ASSERTED))
    assert_predicate result, :saved?, "arrangement failed: the first write did not commit"
    result
  end

  def arguments(body:, digest:, key: "idem-digest-authority")
    remember_arguments(
      body: body,
      envelope: mutation_envelope(idempotency_key: key, request_digest: digest)
    )
  end

  def varied(current)
    case current
    when Integer then current + 1
    when String then "#{current}-varied"
    else { "session_id" => "varied" }
    end
  end
end
