# frozen_string_literal: true

require_relative "../test_helper"
require "kioku/agent/path_resolver"

# "Host filesystem authority stays here" [plan §3 context-agent row];
# "resolve source paths/symlinks within approved roots" [plan §6.3; research §18];
# "Scope is enforced at every boundary" [plan invariant 5].
class KiokuAgentPathResolverTest < Minitest::Test
  def resolver(roots)
    Kioku::Agent::PathResolver.new(approved_roots: roots)
  end

  # approved/, approved-evil/ and outside/ are siblings, so a naive string-prefix
  # containment check passes some of these and fails the suite.
  def with_roots
    with_workspace do |dir|
      approved = File.join(dir, "approved")
      write_file(File.join(approved, "src", "main.rb"), "puts 1\n")
      write_file(File.join(dir, "approved-evil", "secret.txt"), "sibling secret\n")
      write_file(File.join(dir, "outside", "secret.txt"), "outside secret\n")
      yield(dir, approved)
    end
  end

  def test_should_return_the_real_path_when_the_target_is_inside_an_approved_root
    with_roots do |_dir, approved|
      target = File.join(approved, "src", "main.rb")

      assert_equal File.realpath(target), resolver([approved]).resolve(target)
    end
  end

  def test_should_resolve_the_approved_root_itself_when_the_root_is_requested
    with_roots do |_dir, approved|
      assert_equal File.realpath(approved), resolver([approved]).resolve(approved)
    end
  end

  def test_should_reject_the_path_when_parent_traversal_escapes_the_approved_root
    with_roots do |_dir, approved|
      escape = File.join(approved, "..", "outside", "secret.txt")

      assert_raises_kioku("kioku.scope_denied", "parent traversal escaped the root") do
        resolver([approved]).resolve(escape)
      end
    end
  end

  def test_should_reject_the_path_when_a_deep_traversal_chain_escapes_the_approved_root
    with_roots do |_dir, approved|
      escape = File.join(approved, "src", "nested", "..", "..", "..", "outside", "secret.txt")

      assert_raises_kioku("kioku.scope_denied", "deep traversal escaped the root") do
        resolver([approved]).resolve(escape)
      end
    end
  end

  # The classic prefix bug: "/w/approved-evil" starts with "/w/approved".
  def test_should_reject_a_sibling_directory_whose_name_shares_the_approved_root_prefix
    with_roots do |dir, approved|
      sibling = File.join(dir, "approved-evil", "secret.txt")

      assert_raises_kioku("kioku.scope_denied", "sibling sharing the root's prefix") do
        resolver([approved]).resolve(sibling)
      end
    end
  end

  def test_should_reject_an_absolute_path_that_lies_outside_every_approved_root
    with_roots do |dir, approved|
      assert_raises_kioku("kioku.scope_denied", "absolute path outside the roots") do
        resolver([approved]).resolve(File.join(dir, "outside", "secret.txt"))
      end
    end
  end

  # Deny by default: no approved root means no readable path at all.
  def test_should_reject_every_path_when_no_root_has_been_approved
    with_roots do |_dir, approved|
      assert_raises_kioku("kioku.scope_denied", "empty approved-root list") do
        resolver([]).resolve(File.join(approved, "src", "main.rb"))
      end
    end
  end

  def test_should_resolve_the_target_when_it_lies_under_the_second_approved_root
    with_roots do |dir, approved|
      second = File.join(dir, "outside")
      target = File.join(second, "secret.txt")

      assert_equal File.realpath(target), resolver([approved, second]).resolve(target)
    end
  end

  # A relative path is meaningless without a root binding; it must not be resolved
  # against the agent's working directory.
  def test_should_reject_the_path_when_it_is_relative_rather_than_root_anchored
    with_roots do |_dir, approved|
      assert_raises_kioku("kioku.scope_denied", "relative path") do
        resolver([approved]).resolve("src/main.rb")
      end
    end
  end

  def test_should_reject_a_symlink_whose_target_resolves_outside_the_approved_root
    with_roots do |dir, approved|
      skip_without_symlinks(dir)
      link = File.join(approved, "src", "leak.txt")
      File.symlink(File.join(dir, "outside", "secret.txt"), link)

      assert_raises_kioku("kioku.scope_denied", "symlink escaping the root") do
        resolver([approved]).resolve(link)
      end
    end
  end

  def test_should_reject_a_symlinked_directory_whose_target_resolves_outside_the_approved_root
    with_roots do |dir, approved|
      skip_without_symlinks(dir)
      link = File.join(approved, "elsewhere")
      File.symlink(File.join(dir, "outside"), link)

      assert_raises_kioku("kioku.scope_denied", "symlinked directory escaping the root") do
        resolver([approved]).resolve(File.join(link, "secret.txt"))
      end
    end
  end

  # Non-vacuousness: symlinks are resolved, not banned, and the resolved real path
  # is what the caller gets back.
  def test_should_return_the_link_target_real_path_when_a_symlink_stays_inside_the_root
    with_roots do |dir, approved|
      skip_without_symlinks(dir)
      link = File.join(approved, "alias.rb")
      target = File.join(approved, "src", "main.rb")
      File.symlink(target, link)

      assert_equal File.realpath(target), resolver([approved]).resolve(link)
    end
  end
end
