# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/core_stack"
require_relative "support/e2e_case"

# B2 — the complete path, end to end, with the core answering.
#
# context_remember issued at bin/context-mcp -> private host Unix socket ->
# bin/context-agent -> authenticated loopback bridge -> Rails route ->
# Context::Services::Memories::Remember -> canonical commit -> receipt back out
# to the MCP caller. That is the path contracts.json declares
# (envelope.transport_and_actor.path) and the one the two halves have never
# exchanged an envelope over: bin/context-agent does not exist and /api/v1 is an
# empty namespace, so Kioku::Agent::Spool, Kioku::Agent::PathResolver,
# Kioku::ContentAddress and Kioku::RequestDigest have no callers at all.
#
# `saved` is asserted against the receipt and against a replay, not against the
# absence of an error: a replay that hands back the same receipt_id is only
# possible if an idempotency_receipts row was committed in PostgreSQL, which is
# what canonical commit means.
class KiokuRememberSavedPathTest < Minitest::Test
  include Kioku::TestSupport::E2eCase

  PROJECT_KEY = "kioku-e2e"

  def setup
    failure = Kioku::TestSupport::CoreStack.readiness_failure
    flunk(<<~MESSAGE) if failure
      the core is not ready, so the end-to-end path cannot be exercised: #{failure}.
      Start it with `docker compose up -d` from the repository root. This case does not
      skip: an end-to-end path that was never exercised has not been shown to work.
    MESSAGE

    @fixture = fixture
  end

  def test_should_report_the_write_as_saved_with_a_canonical_receipt_when_the_core_commits
    envelope = remember("idem-saved-#{SecureRandom.hex(6)}")

    assert_equal "success", envelope["status"], detail(envelope)
    assert_equal true, envelope.dig("data", "saved"),
                 "saved is returned only after canonical commit; #{detail(envelope)}"
    assert_equal 1, envelope.dig("data", "revision")
    assert_equal "project", envelope.dig("data", "store_kind")
    assert_equal PROJECT_KEY, envelope.dig("data", "owner", "project_key")
    refute_nil envelope.dig("receipt", "receipt_id")
    refute_nil envelope.dig("receipt", "committed_at"), "a canonical receipt carries committed_at"
    assert_equal false, envelope.dig("receipt", "replayed")
  end

  # "The agent acknowledges/retires spool entries only after the canonical
  # receipt" [plan §7.1 step 6]. A committed write must leave nothing behind.
  def test_should_retire_the_spool_entry_once_the_canonical_receipt_arrives
    with_agent(core_url: core_url, bridge_token: bridge_token) do |agent|
      with_mcp(agent) do |mcp|
        message = mcp.call_tool("context_remember", arguments("idem-retire-#{SecureRandom.hex(6)}"))
        envelope = envelope_of(message, agent, "committed context_remember")

        assert_equal true, envelope.dig("data", "saved"), detail(envelope)
        assert_equal 0, spool_at(agent.spool_dir).pending_count,
                     "a write that reached canonical commit left an entry on the host spool"
      end
    end
  end

  def test_should_return_the_prior_canonical_receipt_when_the_same_write_is_replayed
    key = "idem-replay-#{SecureRandom.hex(6)}"

    with_agent(core_url: core_url, bridge_token: bridge_token) do |agent|
      with_mcp(agent) do |mcp|
        first = envelope_of(mcp.call_tool("context_remember", arguments(key)), agent, "first write")
        replayed = arguments(key)
        second = envelope_of(mcp.call_tool("context_remember", replayed), agent, "replay")

        assert_equal first.dig("data", "memory_key"), second.dig("data", "memory_key"),
                     "a replay must resolve to the memory the first call committed"
        assert_equal first.dig("receipt", "receipt_id"), second.dig("receipt", "receipt_id")
        assert_equal true, second.dig("receipt", "replayed")
      end
    end
  end

  # The mirror of the queued cases: with the core answering, the durable label
  # the caller reads is `saved`, and the spool receipt fields that only belong to
  # a queued answer are absent.
  def test_should_not_carry_a_spool_receipt_when_the_write_reached_canonical_commit
    envelope = remember("idem-nospool-#{SecureRandom.hex(6)}")

    assert_equal "success", envelope["status"], detail(envelope)
    assert_nil envelope.dig("data", "spool"),
               "the spool receipt belongs to a queued answer only"
  end

  private

  def core_url
    Kioku::TestSupport::CoreStack.core_url
  end

  def bridge_token
    Kioku::TestSupport::CoreStack.bridge_token
  end

  def fixture
    self.class.arranged_fixture
  rescue StandardError => error
    flunk("could not arrange the end-to-end fixture: #{error.message}")
  end

  # Arranged once per process: the installation, project and scope are idempotent
  # setup rows, and one retained object can back more than one memory.
  def self.arranged_fixture
    @arranged_fixture ||=
      Kioku::TestSupport::CoreStack.arrange_remember_fixture(project_key: PROJECT_KEY)
  end

  def arguments(idempotency_key)
    remember_arguments(project_key: @fixture.fetch("project_key"),
                       object_key: @fixture.fetch("object_key"),
                       idempotency_key: idempotency_key)
  end

  def remember(idempotency_key)
    with_agent(core_url: core_url, bridge_token: bridge_token) do |agent|
      with_mcp(agent) do |mcp|
        envelope_of(mcp.call_tool("context_remember", arguments(idempotency_key)), agent,
                    "context_remember against the running core")
      end
    end
  end
end
