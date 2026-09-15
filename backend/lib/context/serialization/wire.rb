# frozen_string_literal: true

module Context
  module Serialization
    # Renders a Ruby structure as the JSON shape the frozen contract describes:
    # keys become strings and enum symbols become their wire spelling, while
    # numbers, booleans, strings and nil pass through untouched.
    #
    # Shared by every surface so the HTTP boundary and the MCP adapter cannot
    # drift into two spellings of the same envelope (plan 1.4, DRY).
    module Wire
      module_function

      def render(value)
        case value
        when Hash then value.to_h { |key, nested| [key.to_s, render(nested)] }
        when Array then value.map { |element| render(element) }
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
