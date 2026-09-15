# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/e2e_case"

# B2 — the host half of the one complete path, with the core unreachable.
#
# There is no bin/context-agent, so context-mcp has never had anything to talk
# to: every MCP case in this suite is core-unreachable by construction and the
# success path has never executed. These cases put the real agent between the
# real context-mcp and a core that is genuinely not listening, and assert the
# one distinction the whole system rests on:
#
#   "queued means durable host enqueue only; saved means canonical commit. A
#    timeout or missing acknowledgment is never reported as a save"
#   [contracts: notes; errors kioku.queued; plan invariant 2].
#
# Every assertion here reads a durability label out of a response that actually
# carries one. A refusal that carried no data at all would satisfy "not saved"
# vacuously, so the cases assert the field is present AND false, and that the
# capture really is on the spool afterwards.
class KiokuRememberQueuedPathTest < Minitest::Test
  include Kioku::TestSupport::E2eCase

  def test_should_answer_queued_and_not_saved_when_the_core_cannot_be_reached
    with_agent(core_url: unreachable_core_url) do |agent|
      envelope = remember_over_mcp(agent, "idem-queued-1")

      assert_equal "queued", envelope["status"],
                   "a write the core never saw is queued, not success and not a bare failure"
      assert envelope.fetch("data").key?("saved"),
             "a queued response must carry the saved discriminator, not omit it"
      assert_equal false, envelope.dig("data", "saved")
      assert_equal "kioku.queued", envelope.dig("error", "code"),
                   "queued is not a failure but still carries its code so a caller branches once"
    end
  end

  def test_should_carry_the_durable_spool_receipt_when_a_write_is_queued
    with_agent(core_url: unreachable_core_url) do |agent|
      envelope = remember_over_mcp(agent, "idem-queued-2")
      spool = envelope.dig("data", "spool")

      refute_nil spool, "a queued write reports the spool entry it was durably enqueued as"
      %w[spool_entry_id producer_key producer_epoch producer_sequence].each do |field|
        refute_nil spool[field], "the spool receipt omits #{field}"
      end
      assert_nil envelope.dig("receipt", "committed_at"),
                 "a queued write has no canonical commit time"
    end
  end

  # `queued` is a durability claim, so the capture has to be on disk and has to
  # survive the process that made the claim.
  def test_should_leave_the_capture_pending_on_the_durable_spool_when_a_write_is_queued
    with_agent(core_url: unreachable_core_url) do |agent|
      envelope = remember_over_mcp(agent, "idem-queued-3", title: "Queued capture survives")
      entry_id = envelope.dig("data", "spool", "spool_entry_id")

      pending = spool_at(agent.spool_dir).pending

      assert_equal [entry_id], pending.map(&:spool_entry_id),
                   "the write was reported queued but the spool at #{agent.spool_dir} holds " \
                   "#{pending.size} entries"
      assert_equal "Queued capture survives", pending.first.envelope.dig("title"),
                   "the spooled capture must be the one the caller sent"
    end
  end

  def test_should_never_render_a_queued_write_as_saved_anywhere_in_the_tool_result
    with_agent(core_url: unreachable_core_url) do |agent|
      with_mcp(agent) do |mcp|
        message = mcp.call_tool("context_remember",
                                remember_arguments(project_key: "kioku", object_key: "object-1",
                                                   idempotency_key: "idem-queued-4"))
        text = message.dig("result", "content", 0, "text").to_s

        refute_empty text, "the tool result carried no text content to inspect"
        refute_includes text.delete(" "), '"saved":true',
                        "a queued write was rendered as saved somewhere in the tool result: #{text[0, 600]}"
      end
    end
  end

  # Same key, same digest, no canonical receipt yet: the caller gets the prior
  # spool receipt and the capture is not enqueued twice.
  def test_should_return_the_same_spool_entry_when_a_queued_write_is_retried_with_the_same_digest
    with_agent(core_url: unreachable_core_url) do |agent|
      with_mcp(agent) do |mcp|
        arguments = remember_arguments(project_key: "kioku", object_key: "object-1",
                                       idempotency_key: "idem-queued-5")
        first = envelope_of(mcp.call_tool("context_remember", arguments), agent, "first attempt")
        retried = arguments.merge("envelope" => arguments["envelope"].merge("request_id" => uuid_v7))
        second = envelope_of(mcp.call_tool("context_remember", retried), agent, "retry")

        assert_equal first.dig("data", "spool", "spool_entry_id"),
                     second.dig("data", "spool", "spool_entry_id")
        assert_equal 1, spool_at(agent.spool_dir).pending_count,
                     "a retry with the same idempotency key and digest enqueued the capture twice"
      end
    end
  end

  private

  def remember_over_mcp(agent, idempotency_key, title: "Invoice retry fails under concurrent workers")
    with_mcp(agent) do |mcp|
      message = mcp.call_tool("context_remember",
                              remember_arguments(project_key: "kioku", object_key: "object-1",
                                                 idempotency_key: idempotency_key, title: title))
      envelope_of(message, agent, "context_remember with the core unreachable")
    end
  end
end
