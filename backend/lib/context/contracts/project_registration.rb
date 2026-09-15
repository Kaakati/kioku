# frozen_string_literal: true

module Context
  module Contracts
    # The operator/UI project registration request (Plan §1.2).
    #
    # Registration is not one of the six MCP tools: it is a setup API. It runs
    # in installation scope — expressed as store=global with no project_key —
    # because a project scope cannot authorize the creation of a project that
    # does not exist yet.
    class ProjectRegistration < Data.define(
      :envelope, :project_key, :display_name, :roots, :stack_profile, :descriptor, :lifecycle
    )
      TOOL = "project_register"
      FIELDS = %w[envelope project_key display_name roots stack_profile descriptor lifecycle].freeze
      ROOT_FIELDS = %w[repository_key worktree_key root_path kind].freeze
      ROOT_KINDS = %w[repository worktree].freeze
      STACK_FIELDS = %w[languages frameworks platforms].freeze
      LIFECYCLES = %w[active archived].freeze

      # A project key is a stable identifier chosen at registration. It is never
      # derived from a path, a folder name or a Git remote (Plan §1.2), so the
      # only constraint here is that it is a durable, comparable token.
      KEY_PATTERN = /\A[a-z0-9][a-z0-9_.-]{0,127}\z/

      def initialize(envelope:, project_key:, display_name:, roots:, stack_profile:,
                     descriptor: nil, lifecycle: "active")
        super
      end

      def self.parse(payload, started_at: Time.now.utc)
        request = Validator.hash!(Validator.deep_stringify(payload), field: "request")
        Validator.reject_core_derived!(request)
        Validator.reject_unknown!(request, allowed: FIELDS)
        new(
          envelope: parse_envelope(request, started_at),
          project_key: parse_key(Validator.required(request, "project_key")),
          display_name: Validator.string!(Validator.required(request, "display_name"), field: "display_name", max: 200),
          roots: parse_roots(Validator.required(request, "roots")),
          stack_profile: parse_stack_profile(request["stack_profile"]),
          descriptor: parse_descriptor(request["descriptor"]),
          lifecycle: Validator.enum!(request.fetch("lifecycle", "active"), field: "lifecycle", allowed: LIFECYCLES)
        )
      end

      def self.parse_envelope(request, started_at)
        envelope = Envelope.parse(Validator.required(request, "envelope"), tool: TOOL, mutation: true, started_at: started_at)
        Validator.invalid!("envelope.scope.store", "registration_requires_installation_scope") unless envelope.scope.store == "global"
        envelope
      end

      def self.parse_key(value)
        Validator.string!(value, field: "project_key", max: 128)
        Validator.invalid!("project_key", "malformed") unless KEY_PATTERN.match?(value)
        value
      end

      def self.parse_roots(value)
        Validator.array!(value, field: "roots", min: 1, max: 64).each_with_index.map do |root, index|
          parse_root(Validator.hash!(root, field: "roots[#{index}]"), "roots[#{index}]")
        end.freeze
      end

      def self.parse_root(root, field)
        Validator.reject_unknown!(root, allowed: ROOT_FIELDS, field: field)
        {
          "kind" => Validator.enum!(root.fetch("kind", "repository"), field: "#{field}.kind", allowed: ROOT_KINDS),
          "repository_key" => Validator.string!(Validator.required(root, "repository_key", field: "#{field}.repository_key"),
                                                field: "#{field}.repository_key", max: 128),
          "worktree_key" => root["worktree_key"] && Validator.string!(root["worktree_key"], field: "#{field}.worktree_key", max: 128),
          "root_path" => Validator.string!(Validator.required(root, "root_path", field: "#{field}.root_path"),
                                           field: "#{field}.root_path", max: 4096)
        }.freeze
      end

      def self.parse_stack_profile(value)
        return STACK_FIELDS.to_h { |name| [name, [].freeze] }.freeze if value.nil?

        profile = Validator.hash!(value, field: "stack_profile")
        Validator.reject_unknown!(profile, allowed: STACK_FIELDS, field: "stack_profile")
        STACK_FIELDS.to_h do |name|
          entries = profile[name] || []
          [name, Validator.string_array!(entries, field: "stack_profile.#{name}", max: 32).map(&:downcase).freeze]
        end.freeze
      end

      # A checked-in .kioku/project.json descriptor is a discovery hint, never
      # an access grant: it is recorded, and it authorizes nothing.
      def self.parse_descriptor(value)
        return nil if value.nil?

        descriptor = Validator.hash!(value, field: "descriptor")
        Validator.reject_unknown!(descriptor, allowed: %w[schema_version project_key], field: "descriptor")
        Validator.string!(Validator.required(descriptor, "schema_version", field: "descriptor.schema_version"),
                          field: "descriptor.schema_version", max: 64)
        descriptor.freeze
      end

      private_class_method :parse_envelope, :parse_key, :parse_roots, :parse_root,
                           :parse_stack_profile, :parse_descriptor
    end
  end
end
