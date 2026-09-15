# frozen_string_literal: true

module Context
  module Domain
    module Preferences
      # Effective preference resolution (plan 1.3, plan 4.1 "Domain: pure
      # decisions with explicit inputs"). No database, no collaborators.
      #
      # Authority is resolved before specificity: a project assertion cannot
      # defeat a higher-authority instruction, and an assistant-authored record
      # does not become governing user policy by being repeated. Within the same
      # authority, and only where the rule permits it, an explicit project
      # exception wins inside the project that declared it. Equal-authority
      # disagreement stays visible instead of being settled by recency.
      module Resolve
        # The contract's authority enum in decreasing directness. Plan 1.3 only
        # states user above assistant; the remaining order follows the enum and
        # is not exercised by the preference rules themselves.
        AUTHORITY_RANK = { user: 4, system: 3, tool: 2, assistant: 1, imported: 0 }.freeze

        Applied = Struct.new(:topic, :rule, :override, :rejections, keyword_init: true)

        class << self
          def call(rules:, project_key:, overrides: [])
            in_project = overrides.select { |override| override.project_key == project_key }
            applied = rules
                      .select { |rule| in_scope?(rule, project_key) }
                      .map { |rule| apply_overrides(rule, in_project) }

            Resolution.new(
              decisions: applied.group_by(&:topic).transform_values { |entries| decide(entries) },
              rejected_overrides: applied.flat_map(&:rejections)
            )
          end

          private

          # Plan 1.3: other projects' memories are excluded by default, so a
          # project-owned rule applies only inside the project that declared it.
          def in_scope?(rule, project_key)
            rule.project_key.nil? || rule.project_key == project_key
          end

          def apply_overrides(rule, overrides)
            evaluated = overrides
                        .select { |override| override.target_rule_key == rule.key }
                        .map { |override| [override, rejection(rule, override)] }
            accepted = evaluated.find { |(_, reason)| reason.nil? }&.first

            Applied.new(
              topic: rule.topic,
              rule: rewrite(rule, accepted),
              override: accepted,
              rejections: evaluated.filter_map(&:last)
            )
          end

          def rejection(rule, override)
            return { key: override.key, reason: :insufficient_authority } if
              rank(override.authority) < rank(rule.authority)
            return { key: override.key, reason: :mandatory_global } unless rule.overridable?

            nil
          end

          def rewrite(rule, override)
            return rule if override.nil?
            return nil if override.exclusion?

            override.replacement_statement ? rule.with_statement(override.replacement_statement) : rule
          end

          def decide(entries)
            top = top_authority(entries.filter_map(&:rule))
            statements = top.map(&:statement).uniq

            Resolution::Decision.new(
              rule: statements.one? ? top.first : nil,
              conflicting_rule_keys: statements.size > 1 ? top.map(&:key) : [],
              override_status: override_status(entries, top)
            )
          end

          def top_authority(rules)
            return [] if rules.empty?

            best = rules.map { |rule| rank(rule.authority) }.max
            rules.select { |rule| rank(rule.authority) == best }
          end

          def override_status(entries, top)
            return :overridden_in_project if entries.any?(&:override)
            return :mandatory_global if top.any? { |rule| rule.mandatory? && rule.global? }

            :none
          end

          def rank(authority)
            AUTHORITY_RANK.fetch(authority.to_sym, -1)
          end
        end
      end
    end
  end
end
