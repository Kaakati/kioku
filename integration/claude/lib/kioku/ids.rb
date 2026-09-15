# frozen_string_literal: true

require "securerandom"

module Kioku
  module Ids
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

    module_function

    # RFC 9562 section 5.7: 48-bit big-endian Unix millisecond timestamp, then
    # version 7, then randomness. Time-ordered so spool entries and request ids
    # sort by creation without a separate sequence column.
    def uuid7
      return SecureRandom.uuid_v7 if SecureRandom.respond_to?(:uuid_v7)

      build_uuid7((Time.now.to_f * 1000).floor)
    end

    def build_uuid7(now_ms)
      bytes = [now_ms >> 16, now_ms & 0xFFFF].pack("Nn") + SecureRandom.bytes(10)
      octets = bytes.bytes
      octets[6] = (octets[6] & 0x0F) | 0x70
      octets[8] = (octets[8] & 0x3F) | 0x80
      hex = octets.pack("C*").unpack1("H*")
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end

    def uuid?(value)
      value.is_a?(String) && value.match?(UUID_PATTERN)
    end
  end
end
