# frozen_string_literal: true

module Kioku
  module TestSupport
    # Creates a directory link whose target does not exist, using whichever
    # mechanism the host offers.
    #
    # The point is the branch, not the mechanism. Kioku::Agent::PathResolver
    # canonicalizes one component at a time and, when File.realpath raises
    # SystemCallError, carries the component LEXICALLY. A link to a target that
    # does not exist yet is precisely what reaches that branch: File.exist? is
    # false, File.symlink? is true, and File.realpath raises ENOENT.
    #
    # On Linux and macOS that is a dangling symlink. On Windows, File.symlink
    # needs a privilege the authoring host does not have (which is why the three
    # existing symlink cases in path_resolver_test.rb skip here), but `mklink /J`
    # creates a directory junction with no privilege at all, and Ruby reports a
    # dangling junction the same way: exist? false, symlink? true, realpath
    # ENOENT, lstat.ftype "link". So the same case runs on every host and skips
    # on none.
    module UnresolvableLinks
      # Returns the mechanism used, after asserting the link really does sit on
      # the lexical-fallback branch — otherwise the case would pass vacuously on
      # a host where the link was never created.
      def create_dangling_directory_link(link:, target:)
        mechanism = posix_symlink(link, target) || windows_junction(link, target)
        flunk("could not create a dangling directory link at #{link}; neither File.symlink " \
              "nor `mklink /J` is available, so the lexical-fallback branch cannot be " \
              "exercised on this host") unless mechanism

        refute File.exist?(target), "the link target must not exist for this case to mean anything"
        refute File.exist?(link), "a dangling link must not report as existing"
        assert File.symlink?(link), "Ruby must report the dangling link as a link"
        mechanism
      end

      private

      def posix_symlink(link, target)
        File.symlink(target, link)
        :symlink
      rescue NotImplementedError, Errno::EPERM, Errno::EACCES, Errno::ENOSYS, Errno::EEXIST
        nil
      end

      def windows_junction(link, target)
        return nil unless RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/)

        ok = system("cmd", "/c", "mklink", "/J", windows_path(link), windows_path(target),
                    out: File::NULL, err: File::NULL)
        ok && File.symlink?(link) ? :junction : nil
      end

      def windows_path(path)
        path.tr("/", "\\")
      end
    end
  end
end
