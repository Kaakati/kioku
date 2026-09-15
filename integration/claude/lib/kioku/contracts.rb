# frozen_string_literal: true

require "json"

module Kioku
  # The host deploy unit's reader for the shared kioku.tool.v1 artifact.
  #
  # `contracts/v1/` is the single machine-readable definition of the wire contract and
  # this package carries a generated, committed mirror of it (the host adapter installs
  # onto PATH outside the checkout and cannot read the repository root at runtime). The
  # mirror is byte-checked against the source by contract_mirror_test.rb.
  #
  # The rule the artifact sets: nobody transcribes it by hand. Every enum, bound,
  # pattern, status and error name this package enforces is read from here, so a Ruby
  # constant that restates one is a bug rather than a second opinion.
  module Contracts
    V1 = File.expand_path("contracts/v1", __dir__)

    # A $ref is replaced by what it points at, sibling keywords apply alongside it, and
    # `required` is the UNION of both — which is how the mutation envelope adds
    # idempotency_key and request_digest to the common envelope without restating its
    # properties. Those are the only two $ref forms the artifact uses.
    LOCAL_REF = "#"

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

    # The fully resolved, build-pruned surface for all six tools. The adapter publishes
    # this verbatim as each tool's MCP inputSchema, so the surface a model is shown and
    # the surface this package accepts are one object rather than two descriptions.
    def resolved_tools
      read("conformance/resolved_tools.json")
    end

    def tool_schema(tool)
      resolved_tools.fetch(tool)
    end

    # Properties this contract names and this build does not implement. They are pruned
    # from the published schema and refused BY NAME with kioku.unsupported_operation,
    # never silently dropped: a caller must not believe an override, a link or an
    # attempt record was stored when nothing was.
    def unimplemented(tool)
      entry = read("implemented.json").dig("tools", tool) || {}
      (entry["properties"] || {}).reject { |_, implemented| implemented }.keys
    end

    def envelope_schema(operation)
      file = "envelope.request.schema.json"
      resolve(read(file).fetch("$defs").fetch(operation.to_s), file)
    end

    # --- $ref resolution --------------------------------------------------------

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
      file_part, pointer = node.fetch("$ref").split(LOCAL_REF, 2)
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
