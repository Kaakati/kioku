# frozen_string_literal: true

require "json"

module Context
  module Contracts
    # Reads the frozen Phase 0 JSON contract schemas.
    #
    # The schemas are versioned data files, not Ruby: the Rails loader ignores
    # context/contracts/schemas, and nothing outside this module touches the
    # directory. The generated frontend client and the MCP adapter consume the
    # same files, so the wire contract has exactly one source of truth.
    module SchemaRegistry
      NAMES = %w[
        envelope errors context_search context_fetch context_related
        context_remember context_feedback context_task
      ].freeze

      VERSION = "v1"

      LOCK = Mutex.new
      private_constant :LOCK

      module_function

      # Parsed, deeply frozen schema document. Loaded once per process.
      def fetch(name)
        raise ArgumentError, "unknown contract schema: #{name.inspect}" unless NAMES.include?(name)

        loaded[name]
      end

      # Reads a value out of a schema, failing loudly when the path is absent.
      # Contract code digs enums out of the schemas rather than restating them,
      # so a schema edit cannot silently diverge from the Ruby that enforces it.
      def dig!(name, *path)
        value = fetch(name).dig(*path)
        return value unless value.nil?

        raise ArgumentError, "contract schema #{name}.#{VERSION}.json has no #{path.join('/')}"
      end

      def enum!(name, *path)
        value = dig!(name, *path)
        raise ArgumentError, "#{name}.#{path.join('/')} is not an enum" unless value.is_a?(Array)

        value
      end

      def path_for(name)
        Context.schema_root.join("#{name}.#{VERSION}.json")
      end

      def loaded
        LOCK.synchronize { @loaded ||= NAMES.to_h { |name| [name, load_schema(name)] }.freeze }
      end

      def load_schema(name)
        deep_freeze(JSON.parse(path_for(name).read))
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each do |key, nested|
            deep_freeze(key)
            deep_freeze(nested)
          end
          value.freeze
        when Array
          value.each { |nested| deep_freeze(nested) }
          value.freeze
        else
          value.freeze
        end
      end

      private_class_method :load_schema, :deep_freeze
    end
  end
end
