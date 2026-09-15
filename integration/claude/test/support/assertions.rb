# frozen_string_literal: true

module Kioku
  module TestSupport
    module Assertions
      # Asserts the frozen wire name behind a refused MCP tool call, regardless of
      # whether the adapter renders it as a JSON-RPC error or a tool-result envelope.
      def assert_tool_error(expected_code, message, context)
        actual = McpResult.error_code(message)
        assert_equal expected_code, actual,
                     "#{context}: expected #{expected_code}, got #{summarize(message)}"
      end

      def refute_tool_error(unexpected_code, message, context)
        actual = McpResult.error_code(message)
        refute_equal unexpected_code, actual,
                     "#{context}: must not be refused as #{unexpected_code}: #{summarize(message)}"
      end

      # A refused call must never read as a completed one.
      def assert_not_successful(message, context)
        refute_equal "success", McpResult.status(message), "#{context}: #{summarize(message)}"
      end

      def assert_raises_kioku(expected_code, context)
        error = assert_raises(StandardError, context) { yield }
        assert_respond_to error, :code,
                          "#{context}: expected a Kioku::Error carrying a wire name, got #{error.class}: #{error.message}"
        assert_equal expected_code, error.code, "#{context}: #{error.message}"
        error
      end

      def summarize(message)
        JSON.generate(message)[0, 800]
      end
    end
  end
end
