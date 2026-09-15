# frozen_string_literal: true

# Runs every host/protocol test in this package.
#
#   ruby -Ilib -Itest test/run_all.rb

Dir[File.join(__dir__, "test_*.rb")].sort.each { |file| require file }
