# frozen_string_literal: true

module Context
  module Domain
    module Preferences
      # One stored preference statement, global or project owned, with the
      # authority it was recorded under (plan 1.3, invariant 12).
      class Rule
        ATTRIBUTES = %i[key topic statement authority store_kind project_key
                        category mandatory override_policy recorded_at].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(key:, topic:, statement:, authority:, store_kind:,
                       project_key: nil, category: nil, mandatory: false,
                       override_policy: :permitted, recorded_at: nil)
          @key = key
          @topic = topic.to_sym
          @statement = statement
          @authority = authority.to_sym
          @store_kind = store_kind.to_sym
          @project_key = project_key
          @category = category
          @mandatory = mandatory
          @override_policy = override_policy.to_sym
          @recorded_at = recorded_at
          freeze
        end

        def mandatory?
          mandatory
        end

        def global?
          store_kind == :global
        end

        # Plan 1.3 states one behaviour two ways: an exception applies only
        # "within the same authority and an override-permitting policy", and "a
        # user can label a global rule mandatory; local relaxation then requires
        # authority to amend that rule". Both describe the same refusal, so both
        # are checked here and both are reported as :mandatory_global.
        def overridable?
          !mandatory? && override_policy == :permitted
        end

        # An override does not modify the global record; it changes what the
        # rule says inside one project (plan 1.3).
        def with_statement(replacement)
          self.class.new(**to_h.merge(statement: replacement))
        end

        def to_h
          ATTRIBUTES.to_h { |name| [name, public_send(name)] }
        end
      end
    end
  end
end
