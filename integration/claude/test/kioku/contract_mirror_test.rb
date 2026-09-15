# frozen_string_literal: true

require_relative "../test_helper"
require_relative "contract_fixtures"

# The cross-tree drift guard.
#
# Neither deploy unit can read contracts/v1 at runtime: the backend image's build
# context is ./backend, and the host adapter installs onto PATH outside the
# checkout. Each unit therefore carries a generated, committed mirror inside its
# own boundary, and duplicating the files is only safe because the copies are
# machine-checked.
#
# The host suite is the only one that runs in the repository working tree, so this
# is where the check lives. The backend suite's protection is that its fixtures come
# from its own mirror: a stale mirror makes its conformance cases disagree with the
# host's, and this case names the file.
class ContractMirrorTest < Minitest::Test
  Fixtures = Kioku::TestSupport::ContractFixtures

  def test_should_carry_a_host_mirror_byte_identical_to_the_shared_contract_source
    assert_empty differing(Fixtures::SOURCE, Fixtures::MIRROR),
                 "the host mirror has drifted from contracts/v1; " \
                 "edit contracts/v1 and run contracts/bin/kioku-contracts sync"
  end

  def test_should_carry_a_backend_mirror_byte_identical_to_the_shared_contract_source
    assert_empty differing(Fixtures::SOURCE, Fixtures::BACKEND_MIRROR),
                 "the backend mirror has drifted from contracts/v1; " \
                 "edit contracts/v1 and run contracts/bin/kioku-contracts sync"
  end

  # A file present in one tree and not the other is drift that byte comparison of
  # the shared files alone would never see.
  def test_should_mirror_exactly_the_files_the_shared_contract_source_publishes
    source = Fixtures.source_files

    refute_empty source, "contracts/v1 carries no files; the shared artifact is missing"
    assert_equal source, Fixtures.mirror_files, "host mirror file list"
    assert_equal source, Fixtures.backend_mirror_files, "backend mirror file list"
  end

  # Both suites read their own mirror. If the two mirrors disagree, the two suites
  # are measuring two different contracts and can both be green while the halves
  # cannot talk to each other.
  def test_should_keep_both_deploy_units_reading_the_same_contract
    assert_empty differing(Fixtures::MIRROR, Fixtures::BACKEND_MIRROR),
                 "the two deploy units carry different copies of the contract"
  end

  private

  def differing(left_root, right_root)
    paths = Dir.glob(File.join(left_root, "**", "*.json")).map { |path| path.sub("#{left_root}/", "") }
    paths.reject do |relative|
      right = File.join(right_root, relative)
      File.file?(right) && File.binread(File.join(left_root, relative)) == File.binread(right)
    end.sort
  end
end
