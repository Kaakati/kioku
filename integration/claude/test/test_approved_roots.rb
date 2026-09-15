# frozen_string_literal: true

require "fileutils"
require_relative "test_helper"

class TestApprovedRoots < Minitest::Test
  def with_roots
    Dir.mktmpdir("kioku-roots") do |base|
      approved = File.join(base, "approved")
      outside = File.join(base, "outside")
      FileUtils.mkdir_p([File.join(approved, "src"), outside])
      File.write(File.join(approved, "src", "user.rb"), "class User; end\n")
      File.write(File.join(outside, "secret.txt"), "not yours\n")
      yield Kioku::ApprovedRoots.new([approved]), approved, outside
    end
  end

  def test_resolves_a_path_inside_an_approved_root
    with_roots do |roots, approved, _outside|
      resolved = roots.resolve(File.join(approved, "src", "user.rb"))
      assert File.file?(resolved)
      assert roots.contains?(resolved)
    end
  end

  def test_rejects_a_path_outside_every_root
    with_roots do |roots, _approved, outside|
      error = assert_raises(Kioku::Error) { roots.resolve(File.join(outside, "secret.txt")) }
      assert_equal "kioku.scope_denied", error.code
    end
  end

  def test_rejects_a_traversal_escape
    with_roots do |roots, approved, _outside|
      error = assert_raises(Kioku::Error) { roots.resolve(File.join(approved, "..", "outside", "secret.txt")) }
      assert_equal "kioku.scope_denied", error.code
    end
  end

  # /srv/appliance must not count as living under the approved root /srv/app.
  def test_a_sibling_sharing_a_string_prefix_is_not_contained
    Dir.mktmpdir("kioku-roots") do |base|
      FileUtils.mkdir_p([File.join(base, "app"), File.join(base, "appliance")])
      roots = Kioku::ApprovedRoots.new([File.join(base, "app")])
      assert_raises(Kioku::Error) { roots.resolve(File.join(base, "appliance", "config.rb")) }
    end
  end

  def test_a_symlink_pointing_out_of_the_root_is_rejected
    with_roots do |roots, approved, outside|
      link = File.join(approved, "escape")
      begin
        File.symlink(outside, link)
      rescue NotImplementedError, Errno::EPERM, Errno::EACCES
        skip("this host does not permit creating symlinks")
      end
      error = assert_raises(Kioku::Error) { roots.resolve(File.join(link, "secret.txt")) }
      assert_equal "kioku.scope_denied", error.code
    end
  end

  def test_a_not_yet_created_file_inside_a_root_still_resolves
    with_roots do |roots, approved, _outside|
      resolved = roots.resolve(File.join(approved, "src", "new_file.rb"))
      assert resolved.end_with?("new_file.rb")
    end
  end

  def test_an_unresolvable_root_is_recorded_rather_than_silently_dropped
    roots = Kioku::ApprovedRoots.new(["/definitely/not/a/real/root"])
    assert roots.empty?
    assert_equal 1, roots.unresolved.length
  end

  def test_source_reader_hashes_within_the_root_and_refuses_outside
    with_roots do |roots, approved, outside|
      reader = Kioku::SourceReader.new(roots: roots)
      manifest = reader.manifest(path: File.join(approved, "src", "user.rb"))
      assert_match(/\Asha256:[0-9a-f]{64}\z/, manifest["content_hash"])
      assert_equal true, manifest["exists"]

      denied = reader.validate(path: File.join(outside, "secret.txt"))
      assert_equal false, denied["checked"]
      assert_equal "kioku.scope_denied", denied.dig("error", "code")
    end
  end

  def test_validation_reports_a_hash_mismatch_honestly
    with_roots do |roots, approved, _outside|
      reader = Kioku::SourceReader.new(roots: roots)
      path = File.join(approved, "src", "user.rb")
      assert_equal false, reader.validate(path: path, expected_hash: "sha256:#{'0' * 64}")["matches_indexed"]
      current = reader.manifest(path: path)["content_hash"]
      assert_equal true, reader.validate(path: path, expected_hash: current)["matches_indexed"]
    end
  end
end
