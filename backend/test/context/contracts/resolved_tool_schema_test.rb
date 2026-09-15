# frozen_string_literal: true

require "test_helper"
require_relative "contract_fixtures"

# The core's contract loader must reproduce the shared resolved schema exactly.
#
# Two deploy units each write a thin loader that resolves $ref and prunes by
# implemented.json. Two loaders is one transcription risk, so the artifact writes
# the fully resolved, pruned result for all six tools to
# conformance/resolved_tools.json and both units assert their loader reproduces it
# byte for byte (contract.json loader.golden). Without this, the host and the core
# can validate against two different accepted surfaces and both be green.
class ResolvedToolSchemaTest < ActiveSupport::TestCase
  Fixtures = Kioku::Test::ContractFixtures

  test "should reproduce the shared resolved tool schema for every published tool" do
    divergent = Fixtures.resolved_tools.reject do |tool, resolved|
      Context::Contracts.tool_schema(tool) == resolved
    end

    assert_empty divergent.keys, "the core loader produced a different schema for these tools"
  end

  # The pruning half. A property this build has not implemented is removed from the
  # surface, so the accepted surface and the surface a model is shown are one thing.
  test "should prune every context_remember property this build has not implemented" do
    unimplemented = build_state.reject { |_, implemented| implemented }.keys
    published = Context::Contracts.tool_schema("context_remember").fetch("properties").keys

    assert_empty(unimplemented & published,
                 "the loader kept a property implemented.json declares unimplemented")
  end

  # The companion. Pruning everything would satisfy the case above. D7's whole
  # point is that memory_key, lifecycle and mandatory ARE implemented and were
  # unreachable only because one transcription omitted them.
  test "should keep every context_remember property this build does implement" do
    implemented = build_state.select { |_, flag| flag }.keys
    declared = Fixtures.artifact("tools/context_remember.schema.json").fetch("properties").keys
    expected = declared - build_state.reject { |_, flag| flag }.keys

    published = Context::Contracts.tool_schema("context_remember").fetch("properties").keys

    assert_empty implemented - published, "the loader pruned an implemented property"
    assert_equal expected.sort, published.sort
  end

  # D6, structurally. No request schema may declare a core-derived name as a
  # writable property at any depth, except where the artifact records a reason.
  # This replaces the two runtime name blacklists, which checked different names at
  # different depths and were complete on neither side.
  test "should declare no core-derived name as a writable input without a recorded exemption" do
    names = Fixtures.contract.fetch("core_derived_fields").fetch("names")
    exempt = Fixtures.contract.fetch("core_derived_fields").fetch("exemptions").map { |e| e.fetch("name") }
    declared = Fixtures.resolved_tools.flat_map { |tool, schema| core_derived_in(tool, schema, names) }

    assert_empty declared.reject { |entry| exempt.include?(entry.split(":").last) }.uniq,
                 "these core-derived names are declared as writable inputs"
  end

  # A loader that leaves a $ref behind hands a validator a schema it cannot apply,
  # and the properties behind that reference are then silently unvalidated.
  test "should leave no unresolved reference in the schema the loader hands back" do
    unresolved = Fixtures.resolved_tools.keys.reject do |tool|
      !JSON.generate(Context::Contracts.tool_schema(tool)).include?("$ref")
    end

    assert_empty unresolved, "these resolved schemas still carry a reference"
  end

  private

  def build_state
    Fixtures.artifact("implemented.json").dig("tools", "context_remember", "properties")
  end

  def core_derived_in(tool, node, names, found = [])
    case node
    when Hash
      if node["properties"].is_a?(Hash)
        (node["properties"].keys & names).each { |name| found << "#{tool}:#{name}" }
      end
      node.each_value { |value| core_derived_in(tool, value, names, found) }
    when Array
      node.each { |value| core_derived_in(tool, value, names, found) }
    end
    found
  end
end
