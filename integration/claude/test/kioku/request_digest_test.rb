# frozen_string_literal: true

require_relative "../test_helper"
require "kioku/request_digest"

# "SHA-256 over the canonicalized request body excluding request_id, deadline_ms and
# correlation. Digest input includes project_key, so the same payload in a different
# project is a different request" [contracts: request_fields.request_digest; plan §5.2].
class KiokuRequestDigestTest < Minitest::Test
  def digest(payload)
    Kioku::RequestDigest.compute(payload)
  end

  # Deterministic so that only the field under test varies between two digests.
  def base_envelope
    @base_envelope ||= read_envelope(
      "request_id" => "01930f4e-0f8a-7c21-9f3a-0b3c9a7d21ab",
      "idempotency_key" => "idem-fixed-0001",
      "request_digest" => valid_request_digest("placeholder")
    )
  end

  def remember_payload(overrides = {})
    {
      "tool" => "context_remember",
      "envelope" => base_envelope,
      "kind" => "decision",
      "destination" => { "store_kind" => "project", "project_key" => "kioku" },
      "title" => "Pin rails-paradedb",
      "body" => "Pin the gem so the BM25 surface is reproducible.",
      "evidence" => [{ "ref" => { "evidence_key" => "ev-1" }, "relation" => "supports" }]
    }.merge(overrides)
  end

  def test_should_format_the_digest_as_sha256_and_sixty_four_lowercase_hex_characters
    assert_match(/\Asha256:[0-9a-f]{64}\z/, digest(remember_payload))
  end

  # A retry keeps the idempotency key and issues a new request_id
  # [contracts: request_fields.request_id "Not an idempotency key"].
  def test_should_produce_the_same_digest_when_only_the_request_id_differs
    first = remember_payload
    second = remember_payload
    second["envelope"] = first["envelope"].merge("request_id" => uuid_v7)

    assert_equal digest(first), digest(second)
  end

  def test_should_produce_the_same_digest_when_only_the_deadline_differs
    first = remember_payload
    second = remember_payload
    second["envelope"] = first["envelope"].merge("deadline_ms" => 12_345)

    assert_equal digest(first), digest(second)
  end

  # "Correlation hints only" [contracts: request_fields.correlation].
  def test_should_produce_the_same_digest_when_only_the_correlation_hints_differ
    first = remember_payload
    second = remember_payload
    second["envelope"] = first["envelope"].merge(
      "correlation" => { "session_id" => "s-2", "tool_use_id" => "t-9" }
    )

    assert_equal digest(first), digest(second)
  end

  def test_should_produce_the_same_digest_when_only_the_key_insertion_order_differs
    ordered = remember_payload
    shuffled = ordered.to_a.reverse.to_h
    shuffled["destination"] = ordered["destination"].to_a.reverse.to_h

    assert_equal digest(ordered), digest(shuffled)
  end

  # "the same payload in a different project is a different request" [plan §5.2].
  def test_should_produce_a_different_digest_when_the_project_key_differs
    other = remember_payload("destination" => { "store_kind" => "project", "project_key" => "other" })
    other["envelope"] = other["envelope"].merge(
      "scope" => { "store" => "project", "project_key" => "other" }
    )

    refute_equal digest(remember_payload), digest(other)
  end

  def test_should_produce_a_different_digest_when_the_remembered_body_differs
    changed = remember_payload("body" => "Pin the gem so the BM25 surface is reproducible!")

    refute_equal digest(remember_payload), digest(changed)
  end

  def test_should_produce_a_different_digest_when_an_evidence_link_is_removed
    changed = remember_payload("evidence" => [])

    refute_equal digest(remember_payload), digest(changed)
  end

  # Canonicalization is over values, not their rendering: a numeric revision and its
  # string spelling are different requests.
  def test_should_produce_a_different_digest_when_a_value_type_differs
    numeric = remember_payload("expected_revision" => 4)
    textual = remember_payload("expected_revision" => "4")

    refute_equal digest(numeric), digest(textual)
  end
end
