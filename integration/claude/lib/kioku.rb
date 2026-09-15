# frozen_string_literal: true

# Kioku host package: one implementation shared by three entry points --
# bin/contextctl (hook dispatch and operator commands), bin/context-agent (the
# persistent host service) and bin/context-mcp (the MCP stdio server).
#
# Nothing here boots Rails. Everything required from this file is Ruby stdlib
# plus this package, because interpreter startup for a hook sits inside a
# one-second timeout. Heavier collaborators -- net/http for the bridge, the mcp
# gem for the stdio server -- are required by the entry point that needs them.

require_relative "kioku/version"
require_relative "kioku/errors"
require_relative "kioku/ids"
require_relative "kioku/canonical_json"
require_relative "kioku/envelope"
require_relative "kioku/deadlines"
require_relative "kioku/config"
require_relative "kioku/logger"
require_relative "kioku/bounded_io"
require_relative "kioku/frame"
require_relative "kioku/socket_client"
require_relative "kioku/producer_key"
require_relative "kioku/spool"

module Kioku
  # The six MCP tools. The surface stays at six: project registration and root
  # management belong to operator and UI setup APIs, not to a seventh tool.
  TOOLS = %w[
    context_search context_fetch context_related
    context_remember context_feedback context_task
  ].freeze

  # Tools whose calls are mutations and therefore need an idempotency key, a
  # request digest and (against an existing record) an expected revision.
  # context_task is a mutation for every op except get.
  MUTATION_TOOLS = %w[context_remember context_feedback].freeze

  def self.mutation?(tool, arguments)
    return true if MUTATION_TOOLS.include?(tool)
    return false unless tool == "context_task"

    op = arguments.is_a?(Hash) ? (arguments["op"] || arguments[:op]) : nil
    op != "get"
  end

  def self.spool_for(config)
    Spool.new(
      dir: config.spool_dir,
      producer_key: ProducerKey.for_home(config.home),
      max_bytes: config.spool_max_bytes
    )
  end
end
