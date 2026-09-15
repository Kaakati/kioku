# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../kioku/contract_fixtures"

# The published MCP input schema IS the shared artifact's resolved schema.
#
# The surface a model is shown and the surface the host will accept have to be the
# same object, and the only way to keep two hand-written descriptions of one
# contract in step is to stop having two. `conformance/resolved_tools.json` is the
# artifact's own $ref-resolved, build-pruned result; the host publishes it verbatim.
#
# These cases read the REAL published surface over the REAL stdio transport, so a
# loader that produces the right Hash and an adapter that publishes a different one
# are distinguishable.
class ContractPublishedSchemaTest < Minitest::Test
  include Kioku::TestSupport::McpCase

  Fixtures = Kioku::TestSupport::ContractFixtures

  # The MCP SDK defaults a schema with no root `type` to an object (SEP-2106), so
  # the expectation carries that normalization and nothing else.
  def test_should_publish_the_resolved_shared_schema_verbatim_for_every_tool
    divergent = Fixtures.resolved_tools.reject do |name, resolved|
      schema_for(name) == { "type" => "object" }.merge(resolved)
    end

    assert_empty divergent.keys,
                 "these tools publish a schema that is not the artifact's resolved schema"
  end

  # D7, named so the failure is diagnostic. PERMITTED = %w[envelope kind
  # destination title body evidence applicability] refused memory_key, lifecycle,
  # mandatory and nine more contract-named inputs, and the published schema omitted
  # them too, so a model could not even see that they exist.
  def test_should_publish_every_context_remember_input_the_contract_names_and_this_build_implements
    expected = Fixtures.resolved_tools.fetch("context_remember").fetch("properties").keys

    assert_equal expected.sort, properties_of("context_remember").keys.sort
  end

  # The companion. "Publish everything the contract names" would satisfy the case
  # above and would show a model inputs this build silently drops.
  def test_should_publish_no_context_remember_input_this_build_has_not_implemented
    unimplemented = Fixtures.artifact("implemented.json")
                            .dig("tools", "context_remember", "properties")
                            .reject { |_, implemented| implemented }.keys

    assert_empty(unimplemented & properties_of("context_remember").keys,
                 "the published schema offers a model an input this build refuses")
  end

  # D6. No request schema may declare a core-derived name as a writable property,
  # at any depth, except where the artifact records a reason. This is the structural
  # replacement for the two name blacklists that checked different names at
  # different depths and were complete on neither side.
  def test_should_publish_no_core_derived_name_as_a_writable_input_without_a_recorded_exemption
    names = Fixtures.contract.fetch("core_derived_fields").fetch("names")
    exempt = Fixtures.contract.fetch("core_derived_fields").fetch("exemptions")
                     .map { |entry| entry.fetch("name") }
    declared = []

    tool_schemas.each do |tool, schema|
      each_schema_node(schema) do |node|
        next unless node["properties"].is_a?(Hash)

        (node["properties"].keys & names).each { |name| declared << "#{tool}:#{name}" }
      end
    end

    unexplained = declared.reject { |entry| exempt.include?(entry.split(":").last) }
    assert_empty unexplained.uniq, "these core-derived names are published as writable inputs"
  end

  # The exemptions are not a loophole: each one is a retrieval predicate or a
  # declared provenance input the contract names, and each is recorded with its
  # reason. An exemption with no reason is an unexplained hole in the rule.
  def test_should_record_a_reason_for_every_core_derived_exemption
    exemptions = Fixtures.contract.fetch("core_derived_fields").fetch("exemptions")
    unexplained = exemptions.reject { |entry| entry["reason"].to_s.strip.length.positive? }

    refute_empty exemptions
    assert_empty unexplained, "an exemption from the core-derived rule carries no recorded reason"
  end
end
