# frozen_string_literal: true

module Kioku
  # Path authority for the host. Every filesystem read this package performs
  # goes through here first.
  #
  # Resolution is done on the fully resolved real path, so a symlink that
  # points outside an approved root is rejected rather than followed, and
  # containment is compared per path component so that /srv/appliance does not
  # count as living under the approved root /srv/app.
  class ApprovedRoots
    def initialize(roots)
      @roots = []
      @unresolved = []
      Array(roots).each { |root| register(root) }
      @roots.uniq!
    end

    attr_reader :roots, :unresolved

    def empty?
      @roots.empty?
    end

    # Returns the resolved absolute path, or raises kioku.scope_denied.
    def resolve(path)
      raise Kioku.invalid_request("path must be a non-empty string") unless path.is_a?(String) && !path.empty?

      candidate = real_path(path)
      return candidate if root_for(candidate)

      raise Kioku::Error.new(
        "kioku.scope_denied",
        "path is outside every approved root",
        details: { "approved_root_count" => @roots.length }
      )
    end

    def contains?(path)
      !root_for(real_path(path)).nil?
    rescue Kioku::Error
      false
    end

    def root_for(resolved)
      @roots.find { |root| under?(root, resolved) }
    end

    private

    def register(root)
      resolved = File.realpath(File.expand_path(root))
      File.directory?(resolved) ? @roots << resolved : @unresolved << root
    rescue SystemCallError
      @unresolved << root
    end

    # Resolves symlinks on the whole path. A path that does not exist yet is
    # resolved through its parent directory so a not-yet-created file still
    # cannot escape via a symlinked parent.
    def real_path(path)
      expanded = File.expand_path(path)
      return File.realpath(expanded) if File.exist?(expanded)

      File.join(File.realpath(File.dirname(expanded)), File.basename(expanded))
    rescue SystemCallError => e
      raise Kioku::Error.new(
        "kioku.handle_unresolved",
        "path could not be resolved",
        details: { "errno" => e.class.name }
      )
    end

    def under?(root, candidate)
      return true if root == candidate

      prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
      candidate.start_with?(prefix)
    end
  end
end
