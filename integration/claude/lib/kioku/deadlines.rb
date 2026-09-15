# frozen_string_literal: true

module Kioku
  # Per-tool deadline defaults and caps from contracts.json.
  #
  # These are inherited targets from Plan section 10, reasoned for a native
  # binary and in-process SQLite. They are NOT measured for Ruby, Rails or
  # PostgreSQL and must be requalified before release. If measurement shows a
  # deadline cannot be met, the required behaviour is unchanged: return no
  # enhancement and report capture status honestly rather than relaxing it.
  module Deadlines
    DEFAULTS = {
      "context_search" => 3_000,
      "context_fetch" => 5_000,
      "context_related" => 3_000,
      "context_remember" => 5_000,
      "context_feedback" => 3_000,
      "context_task" => 5_000
    }.freeze

    CAPS = {
      "context_search" => 10_000,
      "context_fetch" => 15_000,
      "context_related" => 10_000,
      "context_remember" => 15_000,
      "context_feedback" => 10_000,
      "context_task" => 30_000
    }.freeze

    TASK_DEFAULTS = { "get" => 3_000, "assess" => 10_000, "close" => 10_000 }.freeze
    TASK_CAPS = { "get" => 10_000, "assess" => 30_000, "close" => 30_000 }.freeze

    # Extra socket read budget beyond the tool deadline, so the core's own
    # kioku.deadline_exceeded answer wins the race against a host-side timeout.
    SOCKET_GRACE_MS = 1_500

    module_function

    def default_for(tool, op = nil)
      return TASK_DEFAULTS.fetch(op, DEFAULTS.fetch(tool)) if tool == "context_task"

      DEFAULTS.fetch(tool, 5_000)
    end

    def cap_for(tool, op = nil)
      return TASK_CAPS.fetch(op, CAPS.fetch(tool)) if tool == "context_task"

      CAPS.fetch(tool, Kioku::Envelope::MAX_DEADLINE_MS)
    end

    def clamp(tool, op, deadline_ms)
      [deadline_ms, cap_for(tool, op)].min
    end
  end
end
