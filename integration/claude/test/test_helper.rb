# frozen_string_literal: true

# Kioku host-package test harness.
#
# These tests run on host Ruby with no database and no Rails boot
# (Plan §3 "none starts Rails for a hook invocation"; Plan §4.2).
#
# Every expectation in this suite is a restatement of a frozen requirement.
# The frozen sources are cited inline as:
#   [contracts] kioku.tool.v1 frozen Phase 0 contract
#   [plan §N]   docs/kioku-architectural-plan_v1.md
#   [research §N] docs/claude-code-local-memory-research_v1.md

require "minitest/autorun"
require "json"
require "digest"
require "securerandom"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

KIOKU_PACKAGE_ROOT = File.expand_path("..", __dir__)

$LOAD_PATH.unshift(File.join(KIOKU_PACKAGE_ROOT, "lib"))

module Kioku
  module TestSupport
    class HostBinaryMissing < StandardError; end
    class ProtocolTimeout < StandardError; end
    class ProtocolImpurity < StandardError; end

    module Clock
      module_function

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end

Dir[File.join(__dir__, "support", "*.rb")].sort.each { |file| require file }

module Minitest
  class Test
    include Kioku::TestSupport::Envelopes
    include Kioku::TestSupport::Assertions
    include Kioku::TestSupport::Workspace
  end
end
