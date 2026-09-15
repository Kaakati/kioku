# frozen_string_literal: true

module Context
  module Services
    module Memories
      class Remember
        # The inputs of one context_remember call, normalised.
        #
        # A value object only: whether these inputs are acceptable is the
        # service's decision, not this type's.
        class Request
          attr_reader :actor, :envelope, :kind, :title, :body, :evidence,
                      :memory_key, :applicability, :lifecycle,
                      :store_kind, :project_key, :category, :origin_project_key

          def initialize(actor:, envelope:, kind:, destination:, title:, body:, evidence:,
                         memory_key: nil, applicability: nil, mandatory: false,
                         lifecycle: nil)
            @actor = actor
            @envelope = envelope
            @kind = kind
            @title = title
            @body = body
            @evidence = Array(evidence)
            @memory_key = memory_key
            @applicability = applicability
            @mandatory = mandatory
            @lifecycle = lifecycle
            read_destination(destination)
            freeze
          end

          def global?
            store_kind == :global
          end

          def project?
            store_kind == :project
          end

          # memories.project_key is the owner, and a global record owns none
          # (plan 5.2: exactly one destination).
          def owned_project_key
            project? ? project_key : nil
          end

          def mandatory?
            @mandatory
          end

          # Core-derived, never caller-supplied (frozen contract, labels.authority).
          def authority
            actor.authority
          end

          def expected_revision
            envelope.expected_revision
          end

          def applicability_conditions
            return nil if applicability.nil?

            applicability[:conditions] || applicability["conditions"]
          end

          # Plan 1.3: automatically extracted reusable lessons are stored as
          # proposed assistant-authored records; they do not become governing
          # user preferences because several agents repeat them.
          def effective_lifecycle
            return lifecycle if lifecycle

            global? && authority != :user ? :proposed : :active
          end

          private

          def read_destination(destination)
            fields = destination.to_h.transform_keys(&:to_sym)
            @store_kind = fields[:store_kind].to_sym
            @project_key = fields[:project_key]
            @category = fields[:category]
            @origin_project_key = fields[:origin_project_key]
          end
        end
      end
    end
  end
end
