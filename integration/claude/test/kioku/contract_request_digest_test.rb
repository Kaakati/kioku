# frozen_string_literal: true

require_relative "../test_helper"
require_relative "contract_fixtures"
require "kioku/request_digest"
require "kioku/mcp/dispatch"

# E1 — the request digest is recomputed, never trusted.
#
# `Kioku::RequestDigest` implements the contract's canonicalization correctly and
# has no callers. Both halves validate the digest's SHAPE and neither recomputes it
# over the body, so a caller-asserted string decides whether a durability claim is
# replayed. `contract.json request_digest.authority` is unambiguous: "The core
# RECOMPUTES the digest over the received body and compares it to the asserted
# value. A caller-asserted digest never decides a durability claim."
#
# These cases give the module a caller at the host tool boundary, which is the
# earliest point at which the whole body is in hand.
class ContractRequestDigestTest < Minitest::Test
  Fixtures = Kioku::TestSupport::ContractFixtures

  # The one value both deploy units must produce for the same body. A property
  # test cannot catch two canonicalization rules that are each self-consistent and
  # different from one another; a shared literal can.
  #
  # The fixture body arrives carrying the placeholder `envelope.request_digest`,
  # and the pinned value is the digest of that body WITHOUT it. A digest cannot
  # cover itself: if the asserted value were an input, no recomputation could ever
  # be compared against it, and the comparison is the whole point.
  def test_should_produce_the_pinned_digest_for_the_shared_body_ignoring_the_asserted_digest
    assert_equal Fixtures::GOLDEN_REQUEST_DIGEST,
                 Kioku::RequestDigest.compute(Fixtures.golden_digest_body)
  end

  def test_should_exclude_every_field_the_shared_contract_excludes_from_the_digest_input
    excluded = Fixtures.contract.fetch("request_digest").fetch("excluded_fields")
    base = Fixtures.golden_digest_body
    baseline = Kioku::RequestDigest.compute(base)

    differing = excluded.reject do |field|
      envelope = base.fetch("envelope").merge(field => varied_value(base.dig("envelope", field)))
      Kioku::RequestDigest.compute(base.merge("envelope" => envelope)) == baseline
    end

    assert_empty differing, "these declared-excluded envelope fields still changed the digest"
  end

  # The red half of E1 at the host boundary. Today Validators::Remember checks the
  # digest's shape through the envelope parser and never looks at the body, so a
  # stale or invented digest relays to the core untouched and the core replays a
  # receipt for content nobody sent.
  def test_should_refuse_a_mutation_whose_asserted_digest_does_not_describe_the_body_it_arrived_with
    arguments = Fixtures.with_asserted_digest(remember_arguments, stale_digest)

    error = assert_raises(Kioku::Error) { validate(arguments) }

    assert_equal "kioku.invalid_request", error.code
    assert_includes refused_fields(error), "request_digest",
                    "the refusal must name request_digest: #{error.message}"
  end

  # A caller that changes one character of the remembered body and reuses the
  # digest it computed for the previous one is the concrete shape of the defect.
  def test_should_refuse_a_mutation_whose_body_changed_after_the_asserted_digest_was_computed
    original = remember_arguments
    digest = Kioku::RequestDigest.compute(original)
    edited = original.merge("body" => "#{original.fetch('body')} And it was edited after signing.")

    error = assert_raises(Kioku::Error) { validate(Fixtures.with_asserted_digest(edited, digest)) }

    assert_equal "kioku.invalid_request", error.code
  end

  # The companion. Without it the two cases above are satisfied by refusing every
  # mutation, which would take the whole write path down instead of the defect.
  def test_should_accept_a_mutation_whose_asserted_digest_describes_the_body_it_arrived_with
    arguments = remember_arguments
    digest = Kioku::RequestDigest.compute(arguments)

    envelope = validate(Fixtures.with_asserted_digest(arguments, digest))

    assert_equal digest, envelope.request_digest
  end

  private

  def validate(arguments)
    Kioku::Mcp::Dispatch::VALIDATORS.fetch("context_remember").new.call(arguments: arguments)
  end

  def remember_arguments
    Fixtures.golden_digest_body
  end

  # Shape-valid and describing nothing that was sent: exactly what a stale or
  # copied digest looks like on the wire.
  def stale_digest
    "sha256:#{'0123456789abcdef' * 4}"
  end

  def refused_fields(error)
    details = error.details || {}
    Array(details["fields"]) + Array(details["rejected_fields"]) + [error.message]
  end

  def varied_value(current)
    case current
    when Integer then current + 1
    when String then "#{current}-varied"
    else { "session_id" => "varied" }
    end
  end
end
