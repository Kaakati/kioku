# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../kioku/contract_fixtures"
require_relative "../kioku/published_surface"

# "The MCP tool surface stays at six tools" [contracts: envelope.notes; plan §6.2
# "Keep six MCP tools"]. Input schemas are the frozen required/optional inputs
# [contracts: tools[]].
#
# What the six tools publish, field by field, is asserted against the shared artifact
# in contract_published_schema_test.rb. The cases here are the invariants the artifact
# is itself answerable to: six tools and no operator surface, a common envelope on
# every branch, the three retrieval mechanisms and no fourth, and no embedding or
# vector input anywhere. A change to the artifact that broke one of these would leave
# the verbatim-publication case green and turn one of these red, which is the point of
# keeping both.
class McpToolSurfaceTest < Minitest::Test
  include Kioku::TestSupport::McpCase
  include Kioku::TestSupport::PublishedSurface

  Fixtures = Kioku::TestSupport::ContractFixtures

  def test_should_publish_exactly_the_six_frozen_tools_when_tools_list_is_called
    assert_equal Kioku::TestSupport::McpCase::SIX_TOOLS.sort, tool_list.map { |tool| tool["name"] }.sort
  end

  def test_should_publish_no_setup_or_registration_tool_because_those_belong_to_the_operator_api
    # "Project registration and root management belong to operator/UI setup APIs" [plan §6.2].
    offending = tool_list.map { |tool| tool["name"] }.grep(/register|root|admin|sql|exec/i)

    assert_empty offending, "operator-surface tools leaked into the MCP surface: #{offending.inspect}"
  end

  # Every alternative a caller may satisfy has to carry the envelope, not just the
  # schema's top level: context_task is a discriminated union of eight operations, and
  # one branch that forgot the envelope would be one operation nobody could scope or
  # deadline.
  def test_should_require_the_common_envelope_on_every_published_tool_branch
    Kioku::TestSupport::McpCase::SIX_TOOLS.each do |name|
      assert_equal "object", schema_for(name)["type"], "#{name} does not declare an object input"

      branches = request_branches_of(schema_for(name))
      refute_empty branches, "#{name} publishes no request shape at all"
      envelopeless = branches.reject { |branch| Array(branch["required"]).include?("envelope") }

      assert_empty envelopeless, "#{name} publishes #{envelopeless.size} branch(es) that do not " \
                                 "require the common envelope"
    end
  end

  # "mode: enum(exact|lexical|related) — the only three retrieval mechanisms"
  # [contracts: tools context_search.required_inputs]. The contract also records one
  # deprecated alias, mode='solutions', which expands server-side to {mode: lexical,
  # profile: solutions}: a subject route, not a fourth mechanism. So the three
  # mechanisms are asserted by name and every additional value has to be one the
  # artifact records as an alias — an unrecorded fourth mode fails here.
  def test_should_offer_the_three_retrieval_mechanisms_and_no_unrecorded_fourth_mode
    offered = properties_of("context_search").dig("mode", "enum")
    recorded = Fixtures.resolved_tools.dig("context_search", "x-kioku-deprecated-aliases", "mode") || {}

    assert_equal %w[exact lexical related], Array(offered) - recorded.keys
  end

  def test_should_require_both_the_envelope_and_the_mode_on_context_search
    assert_includes required_of("context_search"), "mode"
  end

  # "Embeddings, embedding models, vector search, hybrid search and ANN are removed from
  # scope ... No field, enum value, error code or capability in this contract refers to
  # them" [contracts: retrieval_modes_after_embedding_removal].
  #
  # They are removed as RETRIEVAL MECHANISMS, which is why the mode positions are read
  # by name rather than grepped for the word: `semantic` survives elsewhere in the
  # contract as an edge resolution basis (syntactic|convention|semantic), meaning how a
  # reference was resolved, and refusing that legitimate value would be reading the
  # sentence as being about a string instead of about a search mechanism.
  def test_should_offer_no_semantic_or_hybrid_value_in_any_published_retrieval_mode
    offending = values_offered_across_tools("mode").grep(/\A(semantic|hybrid)\z/i)

    assert_empty offending, "out-of-scope retrieval modes are published: #{offending.inspect}"
  end

  # The embedding machinery has no legitimate spelling anywhere, so this half stays a
  # blanket check across every published enum.
  def test_should_offer_no_vector_or_embedding_value_anywhere_in_the_published_schemas
    offending = all_enum_values.grep(/\A(vector|embedding|ann|knn|rerank)\w*\z/i)

    assert_empty offending, "out-of-scope retrieval values are published: #{offending.inspect}"
  end

  def test_should_expose_no_embedding_or_vector_input_property_anywhere_in_the_published_schemas
    offending = all_property_names.grep(/embed|vector|ann_|rerank|knn/i)

    assert_empty offending, "out-of-scope inputs are published: #{offending.inspect}"
  end

  # "handles: array<TypedHandle> (1..50)" [contracts: tools context_fetch].
  def test_should_bound_context_fetch_handles_between_one_and_fifty
    handles = properties_of("context_fetch").fetch("handles")

    assert_includes required_of("context_fetch"), "handles"
    assert_equal 1, handles["minItems"]
    assert_equal 50, handles["maxItems"]
  end

  # "seeds (1..10)", "edge_kinds (1..8)", "direction: enum(out|in|both)"
  # [contracts: tools context_related.required_inputs].
  def test_should_require_seeds_edge_kinds_and_direction_on_context_related
    %w[seeds edge_kinds direction].each do |field|
      assert_includes required_of("context_related"), field, "#{field} is not required"
    end
    assert_equal %w[out in both], properties_of("context_related").dig("direction", "enum")
  end

  def test_should_bound_context_related_seeds_and_edge_kinds_to_their_frozen_cardinalities
    properties = properties_of("context_related")

    assert_equal 10, properties.dig("seeds", "maxItems")
    assert_equal 1, properties.dig("edge_kinds", "minItems")
    assert_equal 8, properties.dig("edge_kinds", "maxItems")
  end

  # "max_hops: integer (1..2) default 1 — Plan §10 default one hop, two maximum"
  # [contracts: tools context_related.optional_inputs].
  def test_should_cap_context_related_traversal_at_two_hops
    max_hops = properties_of("context_related").fetch("max_hops")

    assert_equal 1, max_hops["minimum"]
    assert_equal 2, max_hops["maximum"]
    assert_equal 1, max_hops["default"]
  end

  # [contracts: tools context_remember.required_inputs].
  def test_should_require_the_evidence_linked_write_fields_on_context_remember
    %w[kind destination title body evidence].each do |field|
      assert_includes required_of("context_remember"), field, "#{field} is not required"
    end
  end

  def test_should_offer_exactly_the_seven_memory_kinds_on_context_remember
    expected = %w[decision constraint correction attempt observation procedure task_checkpoint]

    assert_equal expected, properties_of("context_remember").dig("kind", "enum")
  end

  # "evidence: array (>=1)" — a memory cannot be saved without an evidence link
  # [contracts: tools context_remember; errors kioku.evidence_required].
  def test_should_require_at_least_one_evidence_link_on_context_remember
    assert_equal 1, properties_of("context_remember").dig("evidence", "minItems")
  end

  def test_should_bound_the_remembered_title_and_body_to_their_frozen_lengths
    properties = properties_of("context_remember")

    assert_equal 200, properties.dig("title", "maxLength")
    assert_equal 16_384, properties.dig("body", "maxLength")
  end

  # "action: enum(dispute|useful|irrelevant)" [contracts: tools context_feedback].
  def test_should_offer_exactly_the_three_feedback_actions_on_context_feedback
    assert_equal %w[dispute useful irrelevant], properties_of("context_feedback").dig("action", "enum")
  end

  # "target: object — {memory_key: string, revision: integer} — an exact revision, not a
  # head pointer" [contracts: tools context_feedback.required_inputs].
  def test_should_require_an_exact_target_revision_on_context_feedback
    target = properties_of("context_feedback").fetch("target")

    assert_equal %w[memory_key revision].sort, Array(target["required"]).sort
    assert_equal "integer", target.dig("properties", "revision", "type")
  end

  # [contracts: tools context_task.required_inputs; plan §6.2]. Read through the
  # branches so the eight operations are what is measured, whichever way the published
  # schema discriminates them.
  def test_should_offer_exactly_the_eight_task_operations_on_context_task
    expected = %w[get set_contract record_claim propose plan_check assess checkpoint close]

    assert_equal expected.sort, values_offered_for("context_task", "op").sort
  end

  def test_should_require_the_operation_discriminator_on_every_published_task_branch
    branches = request_branches_of(schema_for("context_task"))

    refute_empty branches, "context_task publishes no request shape at all"
    undiscriminated = branches.reject { |branch| Array(branch["required"]).include?("op") }

    assert_empty undiscriminated, "context_task publishes #{undiscriminated.size} branch(es) that " \
                                  "do not require the operation discriminator"
  end
end
