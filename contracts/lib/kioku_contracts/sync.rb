# frozen_string_literal: true

require "fileutils"
require_relative "../kioku_contracts"

module KiokuContracts
  # Generates the two derived files and the per-unit mirrors, and verifies that
  # what is committed is what the source produces.
  #
  # Two mirrors exist because neither deploy unit can read the repository root
  # at runtime: the backend image's build context is ./backend, and the host
  # adapter is installed on PATH outside the checkout. The duplication is safe
  # only because it is machine-checked - `verify` is the gate, and it is what a
  # future divergence trips over.
  module Sync
    module_function

    # binwrite, not write: on Windows the default text mode turns every "\n"
    # into "\r\n", the artifact digest then depends on which machine ran sync,
    # and `verify` reports drift that is not there. .gitattributes keeps *.json
    # at LF in the repository; this keeps it at LF on disk too.
    def generate
      File.binwrite(File.join(SOURCE, "conformance", "resolved_tools.json"),
                    KiokuContracts.render(KiokuContracts.resolved_tools))
      File.binwrite(File.join(SOURCE, "MANIFEST.json"),
                    KiokuContracts.render(KiokuContracts.manifest))
    end

    def mirror_paths
      MIRRORS.transform_values { |relative| File.join(KiokuContracts.repo_root, relative) }
    end

    def sync
      generate
      mirror_paths.each_value { |destination| copy_tree(destination) }
      KiokuContracts.source_files.size
    end

    def copy_tree(destination)
      FileUtils.rm_rf(destination)
      FileUtils.mkdir_p(destination)
      KiokuContracts.source_files.each do |relative|
        target = File.join(destination, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(File.join(SOURCE, relative), target)
      end
    end

    # Every failure is reported, not just the first: a partial answer would
    # send someone round the loop once per file.
    def verify
      generated_drift + core_derived_drift + vocabulary_drift + mirror_drift
    end

    # contract.json and errors.json carry readable copies of two lists that are
    # defined once elsewhere. Readable copies are worth having; unchecked ones
    # are how this artifact would start drifting from itself.
    def vocabulary_drift
      [
        ["response status", KiokuContracts.read("contract.json").dig("response_status", "values"),
         KiokuContracts.read("common.schema.json").dig("$defs", "response_status", "enum")],
        ["wire name", KiokuContracts.read("errors.json").fetch("errors").keys,
         KiokuContracts.read("errors.json").dig("x-kioku-wire-names", "enum")]
      ].filter_map do |label, left, right|
        next if left.sort == right.sort

        "the #{label} list disagrees with itself: #{(left - right) | (right - left)}"
      end
    end

    def core_derived_drift
      KiokuContracts.core_derived_violations.map do |pointer|
        "#{pointer} declares a core-derived field as a caller input; " \
          "remove it, or record an exemption with its reason in contract.json"
      end
    end

    def generated_drift
      [["conformance/resolved_tools.json", KiokuContracts.render(KiokuContracts.resolved_tools)],
       ["MANIFEST.json", KiokuContracts.render(KiokuContracts.manifest)]].filter_map do |relative, expected|
        actual = File.read(File.join(SOURCE, relative), mode: "rb") rescue nil
        next if actual == expected

        "#{relative} is stale; run `contracts/bin/kioku-contracts sync`"
      end
    end

    def mirror_drift
      mirror_paths.flat_map { |name, destination| compare_tree(name, destination) }
    end

    def compare_tree(name, destination)
      expected = KiokuContracts.source_files
      present = Dir.glob(File.join(destination, "**", "*.json"))
                   .map { |path| path.sub("#{destination}/", "") }.sort

      (expected - present).map { |file| "#{name} mirror is missing #{file}" } +
        (present - expected).map { |file| "#{name} mirror carries stray #{file}" } +
        (expected & present).filter_map { |file| compare_file(name, destination, file) }
    end

    def compare_file(name, destination, relative)
      source = File.read(File.join(SOURCE, relative), mode: "rb")
      mirrored = File.read(File.join(destination, relative), mode: "rb")
      return if source == mirrored

      "#{name} mirror differs from the source at #{relative}"
    end
  end
end
