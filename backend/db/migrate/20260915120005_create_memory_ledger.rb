# frozen_string_literal: true

# The memory aggregate: a stable head, immutable revisions, evidence links and
# feedback (research Appendix A; plan 5.2 "Memory"; plan invariant 4).
#
# Two structures carry most of the weight.
#
# 1. Ownership exclusivity. Plan 5.2: "Memory ownership requires exactly one
#    destination: store_kind='global' with no owner project, or
#    store_kind='project' with a non-null project_key ... never interpret a
#    missing project ID as permission to fall back to global." A row that is both
#    leaks one project's history into every other project's retrieval; a row that
#    is neither is unreachable by any authorized scope while still sitting in the
#    table. Rails validations do not survive a bulk insert or a backfill.
#
# 2. The deferred circular reference between memories.current_revision and
#    memory_revisions. Appendix A: "Insert the memory head and its initial
#    revision in one transaction; the deferred composite foreign key prevents a
#    committed head from pointing to a nonexistent revision." Deferring the check
#    is not waiving it — it still fires at COMMIT.
class CreateMemoryLedger < ActiveRecord::Migration[8.1]
  STORE_KINDS = %w[global project].freeze
  # Plan 1.3 fixes the global engineering vocabulary.
  CATEGORIES = %w[coding_style engineering_decision architecture preferred_library].freeze
  MEMORY_KINDS = %w[decision constraint correction attempt observation procedure
                    task_checkpoint].freeze
  LIFECYCLES = %w[proposed active superseded retracted].freeze
  AUTHORITIES = %w[user assistant tool system imported].freeze
  EVIDENCE_RELATIONS = %w[supports contradicts context].freeze
  FEEDBACK_ACTIONS = %w[dispute useful irrelevant].freeze
  FEEDBACK_DISPOSITIONS = %w[open resolved withdrawn].freeze

  def change
    create_memories
    create_memory_revisions
    add_memory_head_reference
    create_memory_evidence
    create_feedback
  end

  private

  def create_memories
    create_table :memories, id: :text, primary_key: :memory_key do |t|
      t.text :scope_key, null: false
      t.text :store_kind, null: false
      t.text :project_key
      # Plan 5.2: "Origin project is separate nullable provenance metadata for
      # global records" — provenance, never ownership, so deleting a project
      # cannot take an independent global preference with it (plan 5.3).
      t.text :origin_project_key
      t.text :category
      t.bigint :current_revision, null: false
    end

    add_index :memories, :scope_key
    add_index :memories, :project_key
    add_index :memories, :origin_project_key
    add_index :memories, %i[memory_key current_revision], name: "memories_head_reference"
    add_foreign_key :memories, :scopes, column: :scope_key, primary_key: :scope_key
    add_foreign_key :memories, :projects, column: :project_key, primary_key: :project_key
    add_foreign_key :memories, :projects, column: :origin_project_key,
                                          primary_key: :project_key
    add_memory_check_constraints
  end

  def add_memory_check_constraints
    add_check_constraint :memories, "store_kind IN (#{quoted(STORE_KINDS)})",
                         name: "memories_store_kind_vocabulary"
    add_check_constraint :memories,
                         "category IS NULL OR category IN (#{quoted(CATEGORIES)})",
                         name: "memories_category_vocabulary"
    # Revision zero would make a head that points at nothing look valid to the
    # deferred foreign key, only because no such revision can ever exist.
    add_check_constraint :memories, "current_revision >= 1",
                         name: "memories_current_revision_at_least_one"
    add_check_constraint :memories, <<~SQL.squish, name: "memories_one_destination"
      (store_kind = 'global' AND project_key IS NULL)
      OR (store_kind = 'project' AND project_key IS NOT NULL)
    SQL
  end

  def create_memory_revisions
    create_table :memory_revisions, primary_key: %i[memory_key revision] do |t|
      t.text :memory_key, null: false
      t.bigint :revision, null: false
      t.text :kind, null: false
      t.text :title, null: false
      t.text :body, null: false
      t.text :lifecycle, null: false
      t.text :authority, null: false
      # NOT NULL: research §8 requires capture to enter through authenticated
      # ingest, so a revision with no originating event has no attributable
      # authority at all.
      t.text :author_event_key, null: false
      t.text :author_agent_key
      # Valid time is independent of recorded time (contract
      # context_remember.valid_from / valid_until).
      t.timestamptz :valid_from, null: false
      t.timestamptz :valid_until
      t.timestamptz :recorded_at, null: false
    end

    add_index :memory_revisions, :author_event_key
    add_index :memory_revisions, :author_agent_key
    add_foreign_key :memory_revisions, :memories, column: :memory_key,
                                                  primary_key: :memory_key
    add_foreign_key :memory_revisions, :events, column: :author_event_key,
                                                primary_key: :event_key
    add_foreign_key :memory_revisions, :agents, column: :author_agent_key,
                                                primary_key: :agent_key
    add_revision_check_constraints
  end

  def add_revision_check_constraints
    add_check_constraint :memory_revisions, "revision >= 1",
                         name: "memory_revisions_revision_at_least_one"
    add_check_constraint :memory_revisions, "kind IN (#{quoted(MEMORY_KINDS)})",
                         name: "memory_revisions_kind_vocabulary"
    add_check_constraint :memory_revisions, "lifecycle IN (#{quoted(LIFECYCLES)})",
                         name: "memory_revisions_lifecycle_vocabulary"
    add_check_constraint :memory_revisions, "authority IN (#{quoted(AUTHORITIES)})",
                         name: "memory_revisions_authority_vocabulary"
    # An inverted interval makes the delivery predicate `valid_from <= now AND
    # valid_until > now` silently unsatisfiable: the record disappears instead of
    # erroring.
    add_check_constraint :memory_revisions,
                         "valid_until IS NULL OR valid_until > valid_from",
                         name: "memory_revisions_validity_interval_ordered"
  end

  def add_memory_head_reference
    add_foreign_key :memories, :memory_revisions,
                    column: %i[memory_key current_revision],
                    primary_key: %i[memory_key revision],
                    deferrable: :deferred,
                    name: "memories_head_revision_fk"
  end

  def create_memory_evidence
    # Keyed on (memory_key, revision), never on the memory head, so a link cannot
    # drift onto a later revision and let a correction inherit the evidence that
    # supported the statement it corrects.
    create_table :memory_evidence,
                 primary_key: %i[memory_key revision evidence_key relation] do |t|
      t.text :memory_key, null: false
      t.bigint :revision, null: false
      t.text :evidence_key, null: false
      t.text :relation, null: false
    end

    add_index :memory_evidence, :evidence_key, name: "memory_evidence_reverse"
    add_foreign_key :memory_evidence, :memory_revisions,
                    column: %i[memory_key revision], primary_key: %i[memory_key revision]
    add_foreign_key :memory_evidence, :evidence, column: :evidence_key,
                                                 primary_key: :evidence_key
    # The contract's partial-result rule ("Material contrary evidence is never
    # the thing dropped to fit") depends on contradicting links staying
    # distinguishable from supporting ones.
    add_check_constraint :memory_evidence,
                         "relation IN (#{quoted(EVIDENCE_RELATIONS)})",
                         name: "memory_evidence_relation_vocabulary"
  end

  def create_feedback
    create_table :feedback, id: :text, primary_key: :feedback_key do |t|
      t.text :memory_key, null: false
      t.bigint :revision, null: false
      t.text :author_event_key, null: false
      t.text :action, null: false
      t.text :reason, null: false
      t.text :disposition, null: false
    end

    # Appendix A's feedback_target: the delivery filter asks "is there an open
    # dispute against this exact revision" on every candidate.
    add_index :feedback, %i[memory_key revision action disposition], name: "feedback_target"
    add_index :feedback, :author_event_key
    add_foreign_key :feedback, :memory_revisions, column: %i[memory_key revision],
                                                  primary_key: %i[memory_key revision]
    add_foreign_key :feedback, :events, column: :author_event_key, primary_key: :event_key
    add_check_constraint :feedback, "action IN (#{quoted(FEEDBACK_ACTIONS)})",
                         name: "feedback_action_vocabulary"
    add_check_constraint :feedback, "disposition IN (#{quoted(FEEDBACK_DISPOSITIONS)})",
                         name: "feedback_disposition_vocabulary"
  end

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end
end
