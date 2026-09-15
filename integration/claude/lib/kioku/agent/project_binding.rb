# frozen_string_literal: true

module Kioku
  module Agent
    # Resolves a working directory to a registered project.
    #
    # A directory that is not inside a registered approved root stays
    # unresolved. It is never attached to another project's history and never
    # reinterpreted as a global capture: the core surfaces setup state instead.
    class ProjectBinding
      GIT_WALK_LIMIT = 40

      def initialize(config:, roots:)
        @config = config
        @roots = roots
      end

      def resolve(cwd)
        resolved = safe_resolve(cwd)
        return unresolved("path_outside_approved_roots") if resolved.nil?

        root = @roots.root_for(resolved)
        project_key = @config.project_key_for(root)
        return unresolved("root_not_registered", root: root) if project_key.nil?

        bound(project_key, root, resolved)
      end

      private

      def safe_resolve(cwd)
        cwd.is_a?(String) && !cwd.empty? ? @roots.resolve(cwd) : nil
      rescue Kioku::Error
        nil
      end

      def bound(project_key, root, resolved)
        repository = git_root(resolved, root)
        {
          "state" => "resolved", "project_key" => project_key, "root" => root,
          "repository_key" => repository, "worktree_key" => repository,
          "head_ref" => repository ? head_ref(repository) : nil
        }
      end

      def unresolved(reason, root: nil)
        {
          "state" => "unresolved", "project_key" => nil, "root" => root,
          "repository_key" => nil, "worktree_key" => nil, "head_ref" => nil,
          "reason" => reason, "setup_required" => true
        }
      end

      # Walks upward for a .git entry, stopping at the approved root so
      # resolution never reads above the boundary.
      def git_root(start, root)
        current = start
        GIT_WALK_LIMIT.times do
          return current if File.exist?(File.join(current, ".git"))

          parent = File.dirname(current)
          return nil if parent == current || !current.start_with?(root)

          current = parent
        end
        nil
      end

      def head_ref(repository)
        head = File.join(repository, ".git", "HEAD")
        return nil unless File.file?(head)

        File.read(head, 256).strip
      rescue SystemCallError
        nil
      end
    end
  end
end
