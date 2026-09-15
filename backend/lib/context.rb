# frozen_string_literal: true

require "pathname"

# Kioku's application library.
#
# Rails controllers, jobs and the MCP adapter decode input and render output.
# Everything meaningful — contracts, domain policy, transactional storage,
# authorized queries and the shared result representation — lives here
# (Plan §4, §4.1).
#
# Layout under lib/context/:
#   contracts/     versioned request types and the frozen JSON schema data
#   domain/        pure policy with explicit inputs and no I/O
#   services/      one class per meaningful use case, owning its transaction
#   storage/       transactional persistence operations and object access
#   queries/       scope-aware read composition
#   serialization/ the shared API/MCP-facing result representation
module Context
  # The frozen Phase 0 contract identifier. A request declaring a different
  # major is rejected with kioku.unsupported_schema_version before any scope
  # is resolved.
  CONTRACT_ID = "kioku.tool.v1"

  # Schema files are data, not Ruby. The loader is configured to ignore this
  # directory (config.autoload_lib ignore list, Plan §4); they are reached only
  # through Context::Contracts::SchemaRegistry.
  SCHEMA_ROOT = Pathname.new(__dir__).join("context", "contracts", "schemas").freeze

  # Root of the content-addressed object directory. Object bytes live outside
  # the database: no atomic database/filesystem claim is made (Plan §5.1).
  DEFAULT_OBJECT_ROOT = "/var/lib/kioku/objects"

  module_function

  def contract_id = CONTRACT_ID

  def schema_root = SCHEMA_ROOT

  def object_root
    ENV.fetch("KIOKU_OBJECT_ROOT", DEFAULT_OBJECT_ROOT)
  end
end
