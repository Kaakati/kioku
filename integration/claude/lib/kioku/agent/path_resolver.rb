# frozen_string_literal: true

require_relative "../errors"

module Kioku
  module Agent
    # "Host filesystem authority stays here" [plan §3]; "resolve source paths/symlinks
    # within approved roots" [plan §6.3]; "Scope is enforced at every boundary"
    # [plan invariant 5].
    #
    # Containment is decided on the resolved real path, never on the requested spelling,
    # so neither a parent-traversal chain nor a symlink can hand back bytes from outside
    # an approved root. Containment also requires a path separator after the root, so a
    # sibling directory that merely shares the root's name prefix is refused.
    class PathResolver
      ABSOLUTE_PREFIX = %r{\A([A-Za-z]:/|/)}

      # A link the host could not follow is walked here instead of by the kernel,
      # so the walk carries its own budget in place of the kernel's ELOOP limit.
      MAX_LINK_HOPS = 32

      def initialize(approved_roots:)
        @approved_roots = Array(approved_roots).map { |root| approved_root(root) }
      end

      def resolve(path)
        denied!("a path must be absolute to be root-anchored") unless absolute?(path)
        real = canonicalize(path)
        denied!("the resolved path lies outside every approved root") unless contained?(real)
        real
      end

      private

      def approved_root(root)
        raise ArgumentError, "an approved root must be an absolute path, got #{root.inspect}" unless absolute?(root)

        canonicalize(root)
      end

      def absolute?(path)
        path.is_a?(String) && !prefix_of(path).nil?
      end

      def contained?(real)
        @approved_roots.any? { |root| real == root || real.start_with?("#{root}/") }
      end

      # Resolves one component at a time so that a symlink is followed where it sits and
      # ".." is applied to the physical parent of the already-resolved path. A component
      # that does not exist is carried lexically, which keeps a traversal chain through a
      # missing directory resolvable instead of raising.
      def canonicalize(path, hops = MAX_LINK_HOPS)
        components(path).inject(prefix_of(path)) { |current, component| step(current, component, hops) }
      end

      def step(current, component, hops)
        return current if component == "."
        return parent(current) if component == ".."

        real_path(join(current, component), hops)
      end

      def real_path(candidate, hops)
        return candidate unless File.exist?(candidate) || File.symlink?(candidate)

        File.realpath(candidate)
      rescue SystemCallError
        unfollowed(candidate, hops)
      end

      # realpath failed, so the resolved real path of this component is unknown.
      # A component that is simply not there is still carried lexically, which keeps
      # a traversal chain through a directory the caller is about to create
      # resolvable. A component the host reports as a LINK is not: returning the
      # requested spelling for it would decide containment on the spelling, and a
      # link whose target does not exist yet reads out of the root the moment the
      # target appears. Its own target is read and re-anchored instead, so
      # containment is still decided on where the link points.
      def unfollowed(candidate, hops)
        return candidate unless File.symlink?(candidate)

        denied!("a link chain inside an approved root exceeded #{MAX_LINK_HOPS} hops") if hops.zero?

        canonicalize(anchored(candidate, link_target(candidate)), hops - 1)
      end

      def link_target(candidate)
        File.readlink(candidate)
      rescue SystemCallError, NotImplementedError
        denied!("a link inside an approved root could not be read")
      end

      def anchored(candidate, target)
        absolute?(target) ? target : join(parent(candidate), target)
      end

      def parent(current)
        dirname = File.dirname(current)
        dirname == current ? current : dirname
      end

      def join(current, component)
        current.end_with?("/") ? "#{current}#{component}" : "#{current}/#{component}"
      end

      def components(path)
        normalized = normalize(path)
        normalized[prefix_of(path).length..].split("/").reject(&:empty?)
      end

      def prefix_of(path)
        return nil unless path.is_a?(String)

        ABSOLUTE_PREFIX.match(normalize(path))&.[](1)
      end

      def normalize(path)
        path.tr("\\", "/")
      end

      def denied!(detail)
        raise Kioku::Error.new("kioku.scope_denied", message: detail)
      end
    end
  end
end
