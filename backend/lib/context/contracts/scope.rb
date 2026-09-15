# frozen_string_literal: true

module Context
  module Contracts
    # The requested scope of one call.
    #
    # `both` is the default retrieval posture: the active project plus
    # applicable global records. A global operation declares store=global
    # explicitly — it is never reached by omitting project_key, and a missing
    # project binding is never read as permission to fall back to global
    # (Plan invariant 11).
    class Scope < Data.define(
      :store,
      :project_key,
      :repository_key,
      :worktree_key,
      :task_key,
      :cross_project_keys,
      :global_categories,
      :source_view,
      :commit_oid
    )
      FIELDS = %w[
        store project_key repository_key worktree_key task_key
        cross_project_keys global_categories source_view commit_oid
      ].freeze

      def initialize(store:, project_key: nil, repository_key: nil, worktree_key: nil, task_key: nil,
                     cross_project_keys: [], global_categories: [], source_view: "current_worktree",
                     commit_oid: nil)
        super
      end

      def self.parse(payload, field: "scope")
        body = Validator.hash!(Validator.deep_stringify(payload), field: field)
        Validator.reject_unknown!(body, allowed: FIELDS, field: field)
        store = Validator.enum!(Validator.required(body, "store", field: "#{field}.store"),
                                field: "#{field}.store", allowed: Vocabulary.stores)
        scope = new(**attributes(body, store, field))
        scope.validate!(field)
        scope
      end

      def self.attributes(body, store, field)
        {
          store: store,
          project_key: optional_key(body, "project_key", field),
          repository_key: optional_key(body, "repository_key", field),
          worktree_key: optional_key(body, "worktree_key", field),
          task_key: optional_key(body, "task_key", field),
          cross_project_keys: parse_keys(body["cross_project_keys"], "#{field}.cross_project_keys"),
          global_categories: parse_categories(body["global_categories"], field),
          source_view: Validator.enum!(body.fetch("source_view", "current_worktree"),
                                       field: "#{field}.source_view", allowed: Vocabulary.source_views),
          commit_oid: optional_key(body, "commit_oid", field)
        }
      end

      def self.optional_key(body, name, field)
        value = body[name]
        return nil if value.nil?

        Validator.string!(value, field: "#{field}.#{name}", max: 128)
      end

      def self.parse_keys(value, field)
        return [] if value.nil?

        Validator.string_array!(value, field: field, max: 16).freeze
      end

      def self.parse_categories(value, field)
        return [] if value.nil?

        Validator.array!(value, field: "#{field}.global_categories", max: 4).each do |category|
          Validator.enum!(category, field: "#{field}.global_categories", allowed: Vocabulary.global_categories)
        end.freeze
      end

      private_class_method :attributes, :optional_key, :parse_keys, :parse_categories

      def validate!(field = "scope")
        if project_required? && project_key.nil?
          raise Errors::ProjectBindingUnresolved.new(details: { field: "#{field}.project_key", setup_required: true })
        end
        Validator.invalid!("#{field}.commit_oid", "required_for_commit_view") if source_view == "commit" && commit_oid.nil?
        self
      end

      def project_required? = %w[project both].include?(store)
      def project_scoped? = %w[project both].include?(store) && !project_key.nil?
      def global_scoped? = %w[global both].include?(store)
      def cross_project? = !cross_project_keys.empty?

      # Bound into continuation cursors and cache keys so a scope change forces
      # a reset rather than silently reusing another scope's ordering.
      def digest = Canonical.digest(to_h)
    end
  end
end
