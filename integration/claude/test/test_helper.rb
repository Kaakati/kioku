# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "kioku"
require "kioku/schemas"
require "kioku/tool_request"
require "kioku/hooks/dispatcher"
require "kioku/hooks/output"
require "kioku/approved_roots"
require "kioku/source_reader"

module Kioku
  module TestSupport
    UNROUTABLE_SOCKET = "kioku-test-no-such-agent.sock"

    def with_home
      Dir.mktmpdir("kioku-test") do |dir|
        yield Kioku::Config.new(home: dir, file: {}, env: { "KIOKU_HOME" => dir })
      end
    end

    def read_envelope(store: "project", project_key: "demo")
      { "scope" => { "store" => store, "project_key" => project_key }.compact }
    end

    def silent_logger
      Kioku::Logger.new(component: "test", io: StringIO.new, level: "error")
    end
  end
end
