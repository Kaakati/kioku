# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"

module Context
  module Storage
    # The content-addressed object directory.
    #
    # Required object bytes are durably stored before an available evidence
    # reference commits (Plan invariant 3), so #put does the whole durability
    # dance — write to a temporary file in the destination directory, fsync the
    # file, rename atomically, fsync the directory — and returns only once the
    # bytes will survive a crash. It is called outside write transactions: the
    # filesystem and the database do not share one, and no atomic
    # database/filesystem claim is made (Plan §5.1).
    #
    # Content addressing permits byte deduplication. It is not permission:
    # every fetch resolves through an authorized evidence reference, never
    # through a raw hash (Plan §5.3).
    class ObjectStore
      HASH_ALGORITHM = Contracts::Canonical::ALGORITHM
      HEX = /\A[0-9a-f]{64}\z/
      FAN_OUT = 2

      StoredObject = Data.define(:object_key, :content_hash, :hash_algorithm, :byte_length, :path, :deduplicated)

      def initialize(root: Context.object_root)
        @root = root.to_s
      end

      attr_reader :root

      def put(bytes:)
        content = bytes.to_s.b
        hex = ::Digest::SHA256.hexdigest(content)
        destination = path_for(hex)
        return stored(hex, content.bytesize, destination, deduplicated: true) if intact?(destination, content.bytesize)

        write_durably(destination, content)
        stored(hex, content.bytesize, destination, deduplicated: false)
      end

      def available?(content_hash:)
        path = path_for(digest_hex(content_hash))
        File.file?(path)
      end

      def read(content_hash:, byte_range: nil)
        path = path_for(digest_hex(content_hash))
        raise Errors::EvidenceUnavailable.new(details: { reason: "purged" }) unless File.file?(path)
        return File.binread(path) if byte_range.nil?

        File.binread(path, byte_range.size, byte_range.begin)
      end

      def path_for(hex)
        raise Errors::InvalidRequest.new(details: { field: "content_hash", reason: "malformed" }) unless HEX.match?(hex)

        File.join(root, HASH_ALGORITHM, hex[0, FAN_OUT], hex[FAN_OUT, FAN_OUT], hex)
      end

      # Accepts "sha256:<hex>" or a bare hex digest.
      def digest_hex(content_hash)
        content_hash.to_s.delete_prefix("#{HASH_ALGORITHM}:")
      end

      private

      def stored(hex, byte_length, path, deduplicated:)
        StoredObject.new(
          object_key: "#{HASH_ALGORITHM}:#{hex}", content_hash: "#{HASH_ALGORITHM}:#{hex}",
          hash_algorithm: HASH_ALGORITHM, byte_length: byte_length, path: path, deduplicated: deduplicated
        )
      end

      def intact?(path, byte_length)
        File.file?(path) && File.size(path) == byte_length
      end

      def write_durably(destination, content)
        directory = File.dirname(destination)
        FileUtils.mkdir_p(directory)
        temporary = File.join(directory, ".staging-#{SecureRandom.hex(8)}")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL) do |file|
          file.binmode
          file.write(content)
          file.fsync
        end
        File.rename(temporary, destination)
        fsync_directory(directory)
      rescue StandardError
        FileUtils.rm_f(temporary) if temporary
        raise
      end

      # A rename is only durable once the containing directory is synced. Not
      # every platform permits opening a directory for fsync; where it does not,
      # the rename is still atomic and the file's own fsync has already landed.
      def fsync_directory(directory)
        File.open(directory) { |handle| handle.fsync }
      rescue Errno::EACCES, Errno::EISDIR, Errno::EINVAL, Errno::EBADF, NotImplementedError
        nil
      end
    end
  end
end
