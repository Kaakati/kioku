# frozen_string_literal: true

module Context
  module Contracts
    # Every enum the Ruby contracts enforce, read out of the frozen schema
    # files rather than restated here. A typo or an edit in a schema surfaces
    # as a load-time failure instead of as validation that quietly disagrees
    # with the published wire contract.
    module Vocabulary
      LOCK = Mutex.new
      private_constant :LOCK

      module_function

      def stores = cached(:stores) { SchemaRegistry.enum!("envelope", "$defs", "store", "enum") }
      def authorities = cached(:authorities) { SchemaRegistry.enum!("envelope", "$defs", "authority", "enum") }
      def lifecycles = cached(:lifecycles) { SchemaRegistry.enum!("envelope", "$defs", "lifecycle", "enum") }
      def availabilities = cached(:availabilities) { SchemaRegistry.enum!("envelope", "$defs", "availability", "enum") }
      def applicabilities = cached(:applicabilities) { SchemaRegistry.enum!("envelope", "$defs", "applicability", "enum") }
      def statuses = cached(:statuses) { SchemaRegistry.enum!("envelope", "$defs", "status", "enum") }
      def override_statuses = cached(:override_statuses) { SchemaRegistry.enum!("envelope", "$defs", "override_status", "enum") }
      def source_views = cached(:source_views) { SchemaRegistry.enum!("envelope", "$defs", "source_view", "enum") }
      def handle_kinds = cached(:handle_kinds) { SchemaRegistry.enum!("envelope", "$defs", "typed_handle", "properties", "kind", "enum") }

      def global_categories
        cached(:global_categories) { SchemaRegistry.enum!("envelope", "$defs", "global_category", "enum") }
      end

      def evidence_relations
        cached(:evidence_relations) { SchemaRegistry.enum!("envelope", "$defs", "evidence_relation", "enum") }
      end

      def evidence_rejection_reasons
        cached(:evidence_rejection_reasons) do
          SchemaRegistry.enum!("envelope", "$defs", "evidence_rejection_reason", "enum")
        end
      end

      def claim_support_values
        cached(:claim_support_values) { SchemaRegistry.enum!("envelope", "$defs", "claim_support", "properties", "value", "enum") }
      end

      def coverage_states
        cached(:coverage_states) { SchemaRegistry.enum!("envelope", "$defs", "coverage", "properties", "state", "enum") }
      end

      def coverage_gap_kinds
        cached(:coverage_gap_kinds) do
          SchemaRegistry.enum!("envelope", "$defs", "coverage", "properties", "gaps", "items", "properties", "kind", "enum")
        end
      end

      def host_link_states
        cached(:host_link_states) do
          SchemaRegistry.enum!("envelope", "$defs", "generation_vector", "properties", "host_link_state", "enum")
        end
      end

      def memory_kinds = cached(:memory_kinds) { SchemaRegistry.enum!("context_remember", "properties", "kind", "enum") }

      def writable_lifecycles
        cached(:writable_lifecycles) { SchemaRegistry.enum!("context_remember", "properties", "lifecycle", "enum") }
      end

      def store_kinds
        cached(:store_kinds) { SchemaRegistry.enum!("context_remember", "$defs", "destination", "properties", "store_kind", "enum") }
      end

      def retrieval_modes = cached(:retrieval_modes) { SchemaRegistry.enum!("context_search", "properties", "mode", "enum") }
      def task_ops = cached(:task_ops) { SchemaRegistry.enum!("context_task", "properties", "op", "enum") }
      def feedback_actions = cached(:feedback_actions) { SchemaRegistry.enum!("context_feedback", "properties", "action", "enum") }

      # Fields the core derives from the authenticated transport. A request
      # supplying any of them is rejected with kioku.invalid_request.
      def core_derived_fields
        cached(:core_derived_fields) { SchemaRegistry.dig!("envelope", "x-kioku", "core_derived_fields") }
      end

      def deadline_policy = cached(:deadline_policy) { SchemaRegistry.dig!("envelope", "x-kioku", "deadline_policy") }

      def cached(key, &block)
        LOCK.synchronize { (@cache ||= {})[key] ||= block.call }
      end

      private_class_method :cached
    end
  end
end
