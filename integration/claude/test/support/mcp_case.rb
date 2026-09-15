# frozen_string_literal: true

module Kioku
  module TestSupport
    # Shared setup for tests that speak real MCP over the real stdio of bin/context-mcp.
    module McpCase
      SIX_TOOLS = %w[
        context_search context_fetch context_related
        context_remember context_feedback context_task
      ].freeze

      def setup
        @server = StdioServer.new("context-mcp", env: mcp_env).handshake
      end

      def teardown
        @server&.close
      end

      # Overridden by tests that need a different host binding.
      def mcp_env
        {}
      end

      def server
        @server
      end

      def tool_list
        @tool_list ||= @server.tools
      end

      def tool_schemas
        @tool_schemas ||= tool_list.each_with_object({}) do |tool, schemas|
          schemas[tool["name"]] = tool["inputSchema"]
        end
      end

      def schema_for(name)
        tool_schemas.fetch(name) { flunk("tools/list did not publish #{name}") }
      end

      def required_of(name)
        schema_for(name)["required"] || []
      end

      def properties_of(name)
        schema_for(name)["properties"] || {}
      end

      def call_tool(name, arguments)
        @server.call_tool(name, arguments)
      end

      # Walks every nested schema node so an invariant can be checked across the whole
      # published surface rather than only its top level.
      def each_schema_node(node, &block)
        case node
        when Hash
          block.call(node)
          node.each_value { |value| each_schema_node(value, &block) }
        when Array
          node.each { |value| each_schema_node(value, &block) }
        end
      end

      def all_enum_values
        values = []
        tool_schemas.each_value do |schema|
          each_schema_node(schema) do |node|
            values.concat(Array(node["enum"])) if node["enum"].is_a?(Array)
            values << node["const"] if node.key?("const")
          end
        end
        values
      end

      def all_property_names
        names = []
        tool_schemas.each_value do |schema|
          each_schema_node(schema) do |node|
            names.concat(node["properties"].keys) if node["properties"].is_a?(Hash)
          end
        end
        names
      end
    end
  end
end
