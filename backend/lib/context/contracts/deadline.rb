# frozen_string_literal: true

require "time"

module Context
  module Contracts
    # A relative request budget, clamped per tool.
    #
    # deadline_ms is relative rather than an absolute timestamp because host
    # and container clocks are not assumed synchronized; the core computes and
    # echoes deadline_at. The per-tool defaults and caps are inherited Plan §10
    # targets, unmeasured for Ruby/Rails/PostgreSQL, and must be requalified
    # before release. If measurement shows a deadline cannot be met, the
    # required behavior is unchanged: report honestly rather than relax it.
    class Deadline < Data.define(:started_at, :budget_ms, :tool)
      MAX_MS = 30_000

      def self.for(tool:, requested_ms:, op: nil, started_at: Time.now.utc)
        policy = policy_for(tool: tool, op: op)
        requested = requested_ms.nil? ? policy.fetch("default_ms") : Validator.integer!(requested_ms, field: "deadline_ms", min: 1, max: MAX_MS)
        new(started_at: started_at.utc, budget_ms: [requested, policy.fetch("cap_ms")].min, tool: tool)
      end

      def self.policy_for(tool:, op: nil)
        policy = Vocabulary.deadline_policy
        tools = policy.fetch("tools")
        tools[[tool, op].compact.join(".")] || tools[tool] || policy.fetch("fallback")
      end

      def deadline_at = started_at + (budget_ms / 1000.0)
      def deadline_at_iso = deadline_at.utc.iso8601(3)
      def elapsed_ms(now = Time.now.utc) = ((now - started_at) * 1000).round
      def remaining_ms(now = Time.now.utc) = budget_ms - elapsed_ms(now)
      def expired?(now = Time.now.utc) = remaining_ms(now) <= 0

      # Checked before work that could run past the budget. For a write the
      # outcome after expiry is indeterminate by design: the caller retries with
      # the same idempotency key and request digest, and a deadline expiry is
      # never reported as a save.
      def ensure!(now = Time.now.utc)
        raise Errors::DeadlineExceeded.new(details: { budget_ms: budget_ms, elapsed_ms: elapsed_ms(now) }) if expired?(now)

        self
      end
    end
  end
end
