# frozen_string_literal: true

require "digest"
require "time"

module Kioku
  # Host filesystem authority: bounded reads and SHA-256 hashing of approved
  # source, and the source-validation answers the core requests back over the
  # control connection.
  #
  # A validation result describes one instant. It is never cached forward as a
  # standing claim that a file is current, and a file that cannot be read
  # produces an explicit unavailable answer, never a silent match.
  class SourceReader
    MAX_READ_BYTES = 1_048_576
    HASH_CHUNK_BYTES = 262_144
    HASH_ALGORITHM = "sha256"

    def initialize(roots:)
      @roots = roots
    end

    def manifest(path:)
      resolved = @roots.resolve(path)
      return absent(path) unless File.file?(resolved)

      stat = File.stat(resolved)
      {
        "path" => path, "exists" => true, "byte_length" => stat.size,
        "content_hash" => digest(resolved), "hash_algorithm" => HASH_ALGORITHM,
        "modified_at" => stat.mtime.utc.iso8601(3), "observed_at" => now
      }
    rescue SystemCallError => e
      unavailable(path, e)
    end

    def read(path:, max_bytes: MAX_READ_BYTES, byte_start: 0)
      resolved = @roots.resolve(path)
      raise missing(path) unless File.file?(resolved)

      bytes = File.binread(resolved, max_bytes, byte_start).to_s
      manifest(path: path).merge(
        "content" => bytes.force_encoding(Encoding::UTF_8).scrub,
        "returned_bytes" => bytes.bytesize, "byte_start" => byte_start,
        "truncated" => bytes.bytesize >= max_bytes
      )
    rescue SystemCallError => e
      unavailable(path, e)
    end

    # The answer to one bounded source-validation request from the core.
    def validate(path:, expected_hash: nil)
      observed = manifest(path: path)
      matches = expected_hash.nil? ? nil : (observed["content_hash"] == expected_hash)
      {
        "path" => path, "checked" => observed["exists"] == true, "checked_at" => now,
        "observed_content_hash" => observed["content_hash"],
        "hash_algorithm" => HASH_ALGORITHM, "matches_indexed" => matches,
        "availability" => observed["exists"] ? "available" : "missing"
      }
    rescue Kioku::Error => e
      { "path" => path, "checked" => false, "checked_at" => now,
        "observed_content_hash" => nil, "matches_indexed" => nil,
        "availability" => e.code == "kioku.scope_denied" ? "redacted" : "missing",
        "error" => e.to_error_object }
    end

    private

    def digest(resolved)
      sha = Digest::SHA256.new
      File.open(resolved, "rb") do |file|
        while (chunk = file.read(HASH_CHUNK_BYTES))
          sha.update(chunk)
        end
      end
      "#{HASH_ALGORITHM}:#{sha.hexdigest}"
    end

    def absent(path)
      { "path" => path, "exists" => false, "byte_length" => nil, "content_hash" => nil,
        "hash_algorithm" => HASH_ALGORITHM, "modified_at" => nil, "observed_at" => now }
    end

    def unavailable(path, error)
      raise Kioku::Error.new(
        "kioku.evidence_unavailable",
        "approved source could not be read",
        details: { "reason" => "unavailable", "path" => path, "errno" => error.class.name }
      )
    end

    def missing(path)
      Kioku::Error.new(
        "kioku.evidence_unavailable",
        "approved source is not a readable file",
        details: { "reason" => "missing", "path" => path }
      )
    end

    def now
      Time.now.utc.iso8601(3)
    end
  end
end
