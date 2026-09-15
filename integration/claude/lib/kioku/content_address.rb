# frozen_string_literal: true

require "digest"

module Kioku
  # SHA-256 content addressing for evidence handles.
  #
  # "Use Ruby's standard digest support for SHA-256 content addressing; version the hash
  # algorithm in evidence handles" [plan §4.2]. Bytes are hashed as bytes: no text
  # normalization, no line-ending translation, no encoding conversion, so two files that
  # differ only in their line endings are different evidence.
  class ContentAddress < Data.define(:content_hash, :hash_algorithm, :byte_length)
    ALGORITHM = "sha256"

    def self.for(bytes)
      binary = String(bytes).b

      new(content_hash: "#{ALGORITHM}:#{Digest::SHA256.hexdigest(binary)}",
          hash_algorithm: ALGORITHM,
          byte_length: binary.bytesize)
    end
  end
end
