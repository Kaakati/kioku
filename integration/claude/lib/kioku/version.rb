# frozen_string_literal: true

module Kioku
  VERSION = "0.1.0"

  # The frozen Phase 0 contract identifier. A request declaring a different
  # major is rejected with kioku.unsupported_schema_version before any scope is
  # resolved.
  SCHEMA_VERSION = "kioku.tool.v1"

  # Frame marker for the host socket protocol and for the agent-initiated
  # control connection body. Both directions use the same codec.
  FRAME_PROTOCOL = "KIOKU/1"
end
