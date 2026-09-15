# frozen_string_literal: true

module Kioku
  module TestSupport
    # Readers that ask what the published surface OFFERS rather than how one version of
    # it happened to be spelled. Mixed in alongside McpCase, whose `schema_for` and
    # `each_schema_node` they use.
    #
    # The hand-written surface that predated the shared artifact discriminated
    # context_task with a single top-level `op` enum. The artifact discriminates it with
    # a oneOf over eight branches, each pinning `op` with a const and each declaring its
    # own required list. Both publish the same eight operations and both require the
    # common envelope on every branch.
    #
    # A case that reads `properties.op.enum` directly does not merely need rewriting when
    # the spelling changes: against the oneOf shape it reads a key that is not there,
    # gets nil, and compares nil to a literal — so it fails while appearing to measure
    # the operations, and a subtly WRONG oneOf (a branch with no envelope, a ninth
    # operation) would be invisible to it either way.
    module PublishedSurface
      # The alternatives a caller may satisfy. A schema with no union is its own single
      # branch, so callers can treat both shapes the same way.
      def request_branches_of(schema)
        branches = Array(schema["oneOf"]) + Array(schema["anyOf"])

        branches.empty? ? [schema] : branches
      end

      # Every value the named property is offered under anywhere in one tool's schema,
      # whether the schema lists them in one enum or pins one per branch with a const.
      def values_offered_for(tool, property)
        values = []
        each_schema_node(schema_for(tool)) do |node|
          declared = node["properties"]
          next unless declared.is_a?(Hash)

          spec = declared[property]
          next unless spec.is_a?(Hash)

          values.concat(Array(spec["enum"]))
          values << spec["const"] if spec.key?("const")
        end
        values.compact.uniq
      end

      def values_offered_across_tools(property)
        Kioku::TestSupport::McpCase::SIX_TOOLS.flat_map { |tool| values_offered_for(tool, property) }.uniq
      end
    end
  end
end
