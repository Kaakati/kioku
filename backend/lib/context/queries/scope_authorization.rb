# frozen_string_literal: true

module Context
  module Queries
    # Resolves what the authenticated principal is actually allowed to touch.
    #
    # Scope is enforced at every boundary (Plan invariant 5) and denial is
    # uniform: kioku.scope_denied never discloses whether the target exists in
    # another scope. A missing or ambiguous project binding is its own error
    # with setup_required, and it is never reinterpreted as permission to use
    # the global store (Plan invariant 11).
    class ScopeAuthorization
      # Every returned scope is one the principal holds a grant for. Nothing
      # downstream may widen it.
      Authorized = Data.define(:store, :project_key, :cross_project_keys, :repository_key, :worktree_key, :task_key) do
        def project_scoped? = !project_key.nil?
        def global_included? = %w[global both].include?(store)
        def project_keys = ([project_key] + cross_project_keys).compact.uniq
      end

      def initialize(records: Storage::Records)
        @records = records
      end

      def call(actor:, scope:, destination: nil)
        project_key = resolve_project_key(scope, destination)
        store = authorized_store(actor, destination&.store_kind || scope.store)
        authorize_project!(actor, project_key) if project_key
        authorize_root!(project_key, scope) if project_key
        scope.cross_project_keys.each { |key| authorize_project!(actor, key) }
        Authorized.new(store: store, project_key: project_key,
                       cross_project_keys: scope.cross_project_keys, repository_key: scope.repository_key,
                       worktree_key: scope.worktree_key, task_key: scope.task_key)
      end

      private

      attr_reader :records

      # A write to a project destination must name the same project the request
      # is scoped to. Disagreement is a binding failure, not a silent pick.
      def resolve_project_key(scope, destination)
        return scope.project_key if destination.nil?
        return nil if destination.global?

        if scope.project_key && scope.project_key != destination.project_key
          raise Errors::ProjectBindingUnresolved.new(details: { reason: "scope_destination_mismatch", setup_required: true })
        end
        destination.project_key
      end

      # A global operation must be granted outright. `both` is the default
      # retrieval posture, so a principal without the installation grant keeps
      # its project results and simply sees no global ones — the caller reports
      # that as a scope_excluded coverage gap rather than failing the read.
      def authorized_store(actor, requested)
        return "project" if requested == "project"
        return requested if granted?(actor, "installation", actor.installation_id)
        return "project" if requested == "both"

        raise Errors::ScopeDenied.new(details: { scope_kind: "global" })
      end

      def authorize_project!(actor, project_key)
        project = records.project.find_by(project_key: project_key)
        raise Errors::ProjectBindingUnresolved.new(details: { setup_required: true }) if project.nil?
        raise Errors::ScopeDenied.new(details: { scope_kind: "project" }) unless granted?(actor, "project", project_key)

        project
      end

      # An explicitly selected project must still authorize the current root: a
      # repository or worktree the project has not registered does not become
      # its own by being named in a request.
      def authorize_root!(project_key, scope)
        return if scope.repository_key.nil?

        registered = records.project_root.exists?(project_key: project_key, repository_key: scope.repository_key)
        raise Errors::ScopeDenied.new(details: { scope_kind: "repository" }) unless registered
      end

      def granted?(actor, scope_kind, subject_key)
        records.scope_grant.exists?(
          principal_id: actor.principal_id, scope_kind: scope_kind, subject_key: subject_key
        )
      end
    end
  end
end
