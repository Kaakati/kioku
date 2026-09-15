# frozen_string_literal: true

module Kioku
  module Mcp
    # The frozen enumerations of the kioku.tool.v1 tool surface [contracts: tools[];
    # task_operations[]].
    #
    # Embeddings, vector and hybrid search are out of scope, not deferred: the three
    # retrieval mechanisms below are the whole set, and mode=semantic / mode=hybrid are
    # permanently unsupported values rather than absent ones
    # [contracts: retrieval_modes_after_embedding_removal].
    module Vocabulary
      TOOLS = %w[
        context_search context_fetch context_related
        context_remember context_feedback context_task
      ].freeze

      RETRIEVAL_MODES = %w[exact lexical related].freeze
      REMOVED_RETRIEVAL_MODES = %w[semantic hybrid].freeze

      EDGE_KINDS = %w[
        DEFINES IMPORTS REFERENCES MAY_CALL RESOLVES_TO IMPLEMENTS GENERATED_FROM
        CONSUMED_BY CONSTRAINS PROPOSED_FOR REJECTED_IN SUPERSEDES SUPPORTED_BY
        CONTRADICTS ASSESSES DERIVED_FROM OBSERVED_FRAME EXERCISED
      ].freeze

      TRAVERSAL_DIRECTIONS = %w[out in both].freeze
      MAX_HOPS = 2

      FETCH_HANDLE_KINDS = %w[
        memory_revision global_record_revision evidence object source_range
        commit diff observation report receipt packet
      ].freeze

      MEMORY_KINDS = %w[
        decision constraint correction attempt observation procedure task_checkpoint
      ].freeze

      STORE_KINDS = %w[project global].freeze
      GLOBAL_CATEGORIES = %w[coding_style engineering_decision architecture preferred_library].freeze
      EVIDENCE_RELATIONS = %w[supports contradicts context].freeze

      FEEDBACK_ACTIONS = %w[dispute useful irrelevant].freeze

      TASK_OPERATIONS = %w[
        get set_contract record_claim propose plan_check assess checkpoint close
      ].freeze

      CLAIM_MATERIALITY = %w[material informational].freeze
      CLAIM_SUPPORT = %w[unassessed supported_in_scope contradicted inconclusive].freeze
      PROPOSAL_FIELDS = %w[
        problem mechanism expected_effect preconditions change_scope discriminating_check
      ].freeze
      CHECK_KINDS = %w[test inspection analysis review].freeze
      INPUT_ASSURANCE_LEVELS = %w[immutable_snapshot observed_bookends].freeze
      CRITERION_AUTHORITIES = %w[user assistant system].freeze

      # "completed_in_scope is not an accepted checkpoint state; only close can move the
      # projection there" [contracts: task_operations checkpoint].
      CHECKPOINT_STATES = %w[investigating implementing checking blocked interrupted].freeze

      PRECONDITION_KINDS = %w[
        framework_version dependency schema state workload platform constraint
      ].freeze
    end
  end
end
