# frozen_string_literal: true

require "fileutils"

module Kioku
  # A stable per-installation producer identity for spool sequencing. It is
  # created once and then read, so a spool entry written by a hook process and
  # one written by the agent belong to the same producer stream and replay in
  # sequence order.
  module ProducerKey
    module_function

    def for_home(home)
      path = File.join(home, "producer_key")
      existing = read(path)
      return existing if existing

      create(path)
    end

    def read(path)
      value = File.read(path).strip
      value.empty? ? nil : value
    rescue SystemCallError
      nil
    end

    # Created exclusively, so two processes racing on first run agree on one
    # identity rather than each minting its own producer stream.
    def create(path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      value = Kioku::Ids.uuid7
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(value) }
      value
    rescue Errno::EEXIST
      read(path)
    end
  end
end
