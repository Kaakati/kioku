# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/unresolvable_links"
require "kioku/agent/path_resolver"

# O3 — a link the resolver could not follow is reported as a resolved real path.
#
# PathResolver#real_path (path_resolver.rb:60-66) rescues SystemCallError and
# returns the LEXICAL candidate. A link whose target does not exist takes that
# branch: File.symlink? is true, so realpath is called, and realpath raises
# ENOENT. The lexical candidate still sits under the approved root, so
# #contained? says yes and the caller is handed `<approved>/elsewhere` as a path
# it may read — even though that name is a link out of the root. Once the target
# exists, reading it reads outside the root.
#
# "Containment is decided on the resolved real path, never on the requested
# spelling" is the class comment on the file; the rescue is where the resolved
# real path silently becomes the requested spelling again.
#
# Required discrimination: ENOENT on a plain missing component is still carried
# lexically (a traversal chain through a directory that does not exist yet must
# stay resolvable), while a component File.symlink? reports as a link is refused
# or readlinked and re-anchored. The third case below is what keeps the fix from
# being "refuse everything that does not exist".
class KiokuAgentPathResolverLinkContainmentTest < Minitest::Test
  include Kioku::TestSupport::UnresolvableLinks

  def resolver(roots)
    Kioku::Agent::PathResolver.new(approved_roots: roots)
  end

  def with_roots
    with_workspace do |dir|
      approved = File.join(dir, "approved")
      write_file(File.join(approved, "src", "main.rb"), "puts 1\n")
      write_file(File.join(dir, "outside", "secret.txt"), "outside secret\n")
      yield(dir, approved)
    end
  end

  def test_should_reject_a_dangling_link_used_as_a_path_prefix_when_its_target_lies_outside_the_root
    with_roots do |dir, approved|
      link = File.join(approved, "elsewhere")
      create_dangling_directory_link(link: link, target: File.join(dir, "not-created-yet"))

      assert_raises_kioku("kioku.scope_denied", "dangling link prefix escaping the root") do
        resolver([approved]).resolve(File.join(link, "secret.txt"))
      end
    end
  end

  def test_should_reject_a_dangling_link_named_as_the_final_component_of_the_request
    with_roots do |dir, approved|
      link = File.join(approved, "elsewhere")
      create_dangling_directory_link(link: link, target: File.join(dir, "not-created-yet"))

      assert_raises_kioku("kioku.scope_denied", "dangling link as the requested path") do
        resolver([approved]).resolve(link)
      end
    end
  end

  # The discrimination the fix has to keep: a component that is simply not there
  # yet is not a link, and refusing it would break a traversal chain through a
  # directory the caller is about to create.
  def test_should_still_carry_a_plainly_missing_component_lexically_inside_the_approved_root
    with_roots do |_dir, approved|
      requested = File.join(approved, "src", "not_created_yet.rb")

      assert_equal requested, resolver([approved]).resolve(requested),
                   "a missing plain component must stay resolvable; only a component the host " \
                   "reports as a link may be refused"
    end
  end
end
