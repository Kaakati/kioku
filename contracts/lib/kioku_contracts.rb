# frozen_string_literal: true

require "json"
require "digest"

# Build tooling for the shared kioku.tool.v1 contract artifact.
#
# This file is TOOLING, not contract data. The contract itself is the JSON under
# contracts/v1/ and nothing here may add meaning to it: resolving a $ref and
# pruning an unimplemented property are mechanical, and their result is written
# back out as conformance/resolved_tools.json so both deploy units can assert
# their own loaders reproduce it byte for byte.
#
# Dependency-free on purpose. It runs on the host Ruby and inside the backend
# image; the host adapter package depends only on the MCP SDK and must keep
# doing so.
module KiokuContracts
  ROOT = File.expand_path("..", __dir__)
  SOURCE = File.join(ROOT, "v1")

  TOOLS = %w[
    context_search context_fetch context_related
    context_remember context_feedback context_task
  ].freeze

  MIRRORS = {
    "backend" => "backend/lib/context/contracts/schemas/v1",
    "host" => "integration/claude/lib/kioku/contracts/v1"
  }.freeze

  GENERATED = ["conformance/resolved_tools.json", "MANIFEST.json"].freeze

  module_function

  def repo_root
    File.expand_path("..", ROOT)
  end

  def read(relative_path)
    JSON.parse(File.read(File.join(SOURCE, relative_path)))
  end

  def source_files
    Dir.glob(File.join(SOURCE, "**", "*.json"))
       .map { |path| path.sub("#{SOURCE}/", "") }
       .sort
  end

  # --- $ref resolution --------------------------------------------------------

  # A $ref is replaced by what it points at. Sibling keywords are applied
  # alongside it and `required` is the UNION of both, which is how a mutating
  # tool adds idempotency_key and request_digest to the common envelope without
  # restating its properties.
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
    target, target_file = dereference(node["$ref"], base_file)
    resolved = resolve(target, target_file)
    siblings = resolve_hash(node.reject { |key, _| key == "$ref" }, base_file)

    merge_siblings(resolved, siblings)
  end

  def merge_siblings(resolved, siblings)
    return resolved if siblings.empty?

    merged = resolved.merge(siblings)
    required = Array(resolved["required"]) | Array(siblings["required"])
    merged["required"] = required unless required.empty?
    merged
  end

  def dereference(ref, base_file)
    file_part, pointer = ref.split("#", 2)
    file = file_part.to_s.empty? ? base_file : file_part
    [pointer_lookup(read(file), pointer.to_s, ref), file]
  end

  def pointer_lookup(document, pointer, ref)
    pointer.split("/").reject(&:empty?).reduce(document) do |node, raw|
      token = raw.gsub("~1", "/").gsub("~0", "~")
      raise KeyError, "#{ref} does not resolve: no #{token.inspect}" unless node.is_a?(Hash) && node.key?(token)

      node[token]
    end
  end

  # --- pruning by build state -------------------------------------------------

  # A property this build does not implement is removed from the published
  # surface. It is NOT quietly accepted and dropped: supplying it is refused by
  # name with kioku.unsupported_operation, which is what stops a caller
  # believing an override or an attempt record was stored.
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

  def unimplemented_for(tool)
    entry = read("implemented.json").dig("tools", tool) || {}
    (entry["properties"] || {}).reject { |_, implemented| implemented }.keys
  end

  # The accepted surface for one tool: resolved, then pruned. This is exactly
  # what the host publishes as its MCP inputSchema and exactly what either side
  # validates against.
  def tool_schema(tool)
    file = "tools/#{tool}.schema.json"
    prune(resolve(read(file), file), unimplemented_for(tool))
  end

  def resolved_tools
    TOOLS.each_with_object({}) { |tool, out| out[tool] = tool_schema(tool) }
  end

  # --- core-derived field enforcement -----------------------------------------

  # The guarantee is that a caller cannot supply authority or an actor identity.
  # Enforcing it as a runtime name blacklist failed, because a blacklist checked
  # at one depth is bypassed by nesting the name one level deeper. Enforcing it
  # structurally means the name is never a declared property at all, so the
  # closure rule refuses it wherever it appears.
  def request_schema_files
    ["common.schema.json", "envelope.request.schema.json"] +
      TOOLS.map { |tool| "tools/#{tool}.schema.json" }
  end

  def core_derived_violations
    contract = read("contract.json").fetch("core_derived_fields")
    names = contract.fetch("names")
    exempt = contract.fetch("exemptions").map { |entry| entry.fetch("pointer") }

    request_schema_files.flat_map { |file| declared_core_derived(file, names) } - exempt
  end

  def declared_core_derived(file, names, node = nil, pointer = "", found = [])
    node = read(file) if node.nil?
    case node
    when Hash then scan_properties(file, names, node, pointer, found)
    when Array then node.each_with_index { |item, i| declared_core_derived(file, names, item, "#{pointer}/#{i}", found) }
    end
    found
  end

  def scan_properties(file, names, node, pointer, found)
    node.each do |key, value|
      child = "#{pointer}/#{key}"
      if key == "properties" && value.is_a?(Hash)
        value.each_key { |name| found << "#{file}##{child}/#{name}" if names.include?(name) }
      end
      declared_core_derived(file, names, value, child, found)
    end
  end

  # --- digests ----------------------------------------------------------------

  def digest_of(text)
    "sha256:#{Digest::SHA256.hexdigest(text)}"
  end

  def manifest
    files = (source_files - GENERATED).each_with_object({}) do |relative, out|
      out[relative] = digest_of(File.read(File.join(SOURCE, relative), mode: "rb"))
    end
    files["conformance/resolved_tools.json"] = digest_of(render(resolved_tools))

    {
      "contract_id" => read("contract.json").fetch("contract_id"),
      "generated_by" => "contracts/bin/kioku-contracts sync",
      "files" => files.sort.to_h,
      "artifact_digest" => artifact_digest(files)
    }
  end

  def artifact_digest(files)
    digest_of(files.sort.map { |path, sha| "#{path} #{sha}\n" }.join)
  end

  def render(object)
    "#{JSON.pretty_generate(object)}\n"
  end
end
