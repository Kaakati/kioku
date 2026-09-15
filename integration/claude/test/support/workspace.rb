# frozen_string_literal: true

module Kioku
  module TestSupport
    # Real temporary directories for approved-root and spool fixtures.
    module Workspace
      def with_workspace
        Dir.mktmpdir("kioku-host-test") do |dir|
          yield File.realpath(dir)
        end
      end

      def write_file(path, contents)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, contents)
        path
      end

      # Symlink creation needs privileges on the Windows authoring host; the
      # deployment targets are Linux/WSL and macOS (plan §1.4 / CLAUDE.md).
      def symlinks_supported?(dir)
        target = File.join(dir, "__symlink_probe_target")
        link = File.join(dir, "__symlink_probe_link")
        File.binwrite(target, "probe")
        File.symlink(target, link)
        File.symlink?(link)
      rescue NotImplementedError, Errno::EPERM, Errno::EACCES, Errno::ENOSYS, Errno::EEXIST
        false
      ensure
        FileUtils.rm_f([target, link])
      end

      def skip_without_symlinks(dir)
        skip("symlink creation unavailable on this host") unless symlinks_supported?(dir)
      end
    end
  end
end
