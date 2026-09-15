# frozen_string_literal: true

require "open3"
require_relative "test_helper"

# Interpreter startup now sits inside the one-second hook timeout, so what the
# hook path loads is part of the contract. These run in a fresh interpreter
# because the rest of the suite has already loaded everything.
class TestHookStartup < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def loaded_features(script)
    out, err, status = Open3.capture3("ruby", "-I#{LIB}", "-e", script)
    assert status.success?, "child failed: #{err}"
    out.split("\n")
  end

  def hook_path_features
    loaded_features(<<~RUBY)
      require "kioku"
      require "kioku/cli"
      puts $LOADED_FEATURES
    RUBY
  end

  # net/http roughly doubles interpreter startup. Only context-agent and the
  # doctor command may pay for it, and both are off the hook path.
  def test_the_hook_path_does_not_load_net_http
    features = hook_path_features
    assert_empty features.grep(%r{/net/http}), "net/http must not be loaded by the hook path"
  end

  def test_the_hook_path_does_not_load_the_mcp_gem
    features = hook_path_features
    assert_empty features.grep(%r{/mcp[./]}), "the mcp gem must not be loaded by the hook path"
  end

  def test_the_hook_path_does_not_load_rails
    features = hook_path_features
    assert_empty features.grep(/active(record|support|job)|rails/), "no hook may boot Rails"
  end

  def test_the_hook_path_still_loads_what_it_needs
    features = hook_path_features
    %w[socket.so socket.rb json digest securerandom].each do |needed|
      refute_empty features.grep(/#{Regexp.escape(needed)}/), "#{needed} should be available to a hook"
    end
  end

  def test_the_doctor_command_is_what_pulls_in_net_http
    features = loaded_features(<<~RUBY)
      require "kioku"
      require "kioku/doctor"
      puts $LOADED_FEATURES
    RUBY
    refute_empty features.grep(%r{/net/http})
  end
end
