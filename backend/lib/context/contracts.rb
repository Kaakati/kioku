# frozen_string_literal: true

require "json"

module Context
  # The core deploy unit's reader for the shared kioku.tool.v1 artifact.
  #
  # `contracts/v1/` is the single machine-readable definition of the wire contract. The
  # backend image's build context is ./backend, so nothing above it can be COPYed; this
  # unit therefore carries a generated, committed mirror at
  # lib/context/contracts/schemas/v1, which config/application.rb already excludes from
  # autoloading and which the host suite checks byte for byte against the source.
  #
  # The rule the artifact sets: nobody transcribes it by hand. Every enum, bound,
  # pattern, status and error name this core enforces is read from here, so a Ruby
  # constant that restates one is a bug rather than a second opinion.
  module Contracts
    V1 = File.expand_path("contracts/schemas/v1", __dir__)

    module_function

    def read(relative_path)
      cache[relative_path] ||= JSON.parse(File.read(File.join(V1, relative_path)))
    end

    def cache
      @cache ||= {}
    end

    def definition(name)
      read("common.schema.json").fetch("$defs").fetch(name)
    end

    def contract
      read("contract.json")
    end

    def errors
      read("errors.json").fetch("errors")
    end

    def response_statuses
      definition("response_status").fetch("enum")
    end

    def supported_major
      contract.fetch("supported_major")
    end

    def schema_version_pattern
      @schema_version_pattern ||= Regexp.new(definition("schema_version").fetch("pattern"))
    end

    def digest_rule
      contract.fetch("request_digest")
    end

    def envelope_schema(operation)
      file = "envelope.request.schema.json"
      resolve(read(file).fetch("$defs").fetch(operation.to_s), file)
    end

    # The accepted surface for one tool: resolved, then pruned by build state. Two deploy
    # units each write this, so the artifact publishes the answer as
    # conformance/resolved_tools.json and both assert they reproduce it — without that,
    # the host and the core can validate against two different surfaces and both be
    # green [contracts: contract.json loader.golden].
    def tool_schema(tool)
      file = "tools/#{tool}.schema.json"
      prune(resolve(read(file), file), unimplemented(tool))
    end

    # "A property listed false is removed from the published schema and from its required
    # list ... It is never silently dropped" [contracts: implemented.json rules].
    def unimplemented(tool)
      entry = read("implemented.json").dig("tools", tool) || {}
      (entry["properties"] || {}).reject { |_, implemented| implemented }.keys
    end

    def prune(schema, unimplemented)
      return schema if unimplemented.empty?

      pruned = prune_object(schema, unimplemented)
      return pruned unless pruned["oneOf"].is_a?(Array)

      pruned.merge("oneOf" => pruned["oneOf"].map { |branch| prune_object(branch, unimplemented) })
    end

    def prune_object(schema, unimplemented)
      out = schema.dup
      if out["properties"].is_a?(Hash)
        out["properties"] = out["properties"].reject { |name, _| unimplemented.include?(name) }
      end
      out["required"] = Array(out["required"]) - unimplemented if out["required"].is_a?(Array)
      out
    end

    # --- $ref resolution --------------------------------------------------------

    # A $ref is replaced by what it points at. Sibling keywords apply alongside it and
    # `required` is the UNION of both, which is how a mutating tool adds idempotency_key
    # and request_digest to the common envelope without restating its properties. Those
    # are the only two $ref forms the artifact uses.
    def resolve(node, base_file)
      case node
      when Hash then resolve_hash(node, base_file)
      when Array then node.map { |item| resolve(item, base_file) }
      else node
      end
    end

    def resolve_hash(node, base_file)
      return resolve_ref(node, base_file) if node.key?("$ref")

      node.each_with_object({}) { |(key, value), out| out[key] = resolve(value, base_file) }
    end

    def resolve_ref(node, base_file)
      file_part, pointer = node.fetch("$ref").split("#", 2)
      file = file_part.to_s.empty? ? base_file : file_part
      resolved = resolve(pointer_lookup(read(file), pointer.to_s), file)

      merge_siblings(resolved, resolve_hash(node.reject { |key, _| key == "$ref" }, base_file))
    end

    def merge_siblings(resolved, siblings)
      return resolved if siblings.empty?

      merged = resolved.merge(siblings)
      required = Array(resolved["required"]) | Array(siblings["required"])
      merged["required"] = required unless required.empty?
      merged
    end

    def pointer_lookup(document, pointer)
      pointer.split("/").reject(&:empty?).reduce(document) do |node, raw|
        token = raw.gsub("~1", "/").gsub("~0", "~")
        raise KeyError, "#{pointer} does not resolve: no #{token.inspect}" unless node.is_a?(Hash)

        node.fetch(token)
      end
    end
  end
end
