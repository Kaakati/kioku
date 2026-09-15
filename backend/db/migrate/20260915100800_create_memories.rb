# frozen_string_literal: true

# Memory head, immutable revisions and evidence links (Research Appendix A;
# Plan §1.1, §5.2, §5.3).
#
# `memories` is the stable head; `memory_revisions` is append-only history. The
# head and its first revision are inserted in one transaction, which is exactly
# what the deferred composite foreign key below exists to permit.
class CreateMemories < ActiveRecord::Migration[8.1]
  def change
    create_memories_table
    add_memory_indexes_and_foreign_keys
    add_memory_ownership_constraints
    create_memory_revisions_table
    add_memory_revision_indexes_and_foreign_keys
    add_memory_revision_constraints
    add_memory_revision_redaction_constraints
    link_head_to_revision
    create_memory_evidence_table
    install_append_only_guard
  end

  private

  def create_memories_table
    create_table :memories, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :memory_key, null: false
      t.string :scope_key, null: false
      t.string :store_kind, null: false
      t.string :project_key
      # Provenance on a global record: which project the lesson came from.
      # Distinct from ownership; a global record has no owning project.
      t.string :origin_project_key
      t.string :category
      t.bigint :current_revision, null: false
      t.bigint :deletion_epoch, null: false, default: 0
      t.column :created_at, :timestamptz, null: false, default: -> { "now()" }
      t.column :updated_at, :timestamptz, null: false, default: -> { "now()" }
    end
  end

  def add_memory_indexes_and_foreign_keys
    add_index :memories, :memory_key, unique: true
    add_index :memories, %i[scope_key store_kind project_key],
              name: "index_memories_on_ownership_triple"
    add_index :memories, :project_key
    add_index :memories, :origin_project_key
    add_index :memories, %i[store_kind category], name: "index_memories_on_store_kind_and_category"

    add_foreign_key :memories, :projects, column: :project_key, primary_key: :project_key,
                                          name: "fk_memories_project_key"
    add_foreign_key :memories, :projects, column: :origin_project_key, primary_key: :project_key,
                                          name: "fk_memories_origin_project_key"
    add_foreign_key :memories, :scopes, column: %i[scope_key store_kind],
                                        primary_key: %i[scope_key store_kind],
                                        name: "fk_memories_scope_store_kind"
    add_foreign_key :memories, :scopes, column: %i[scope_key store_kind project_key],
                                        primary_key: %i[scope_key store_kind project_key],
                                        name: "fk_memories_scope_ownership"
  end

  def add_memory_ownership_constraints
    add_check_constraint :memories, "btrim(memory_key) <> ''", name: "memories_key_present"
    add_check_constraint :memories, "current_revision >= 1",
                         name: "memories_current_revision_positive"
    add_check_constraint :memories, "deletion_epoch >= 0",
                         name: "memories_deletion_epoch_non_negative"
    add_check_constraint :memories, "store_kind IN ('project', 'global')",
                         name: "memories_store_kind_valid"

    # Exactly one destination (Plan §5.2): global with no owner project, or
    # project with a non-null project_key. Never both, never neither.
    add_check_constraint :memories,
                         "(store_kind = 'project' AND project_key IS NOT NULL) " \
                         "OR (store_kind = 'global' AND project_key IS NULL)",
                         name: "memories_single_ownership_destination"

    # Global engineering records are categorised; project memories are not.
    add_check_constraint :memories,
                         "(store_kind = 'global' AND category IN " \
                         "('coding_style', 'engineering_decision', 'architecture', 'preferred_library')) " \
                         "OR (store_kind = 'project' AND category IS NULL)",
                         name: "memories_category_matches_store_kind"
    add_check_constraint :memories, "origin_project_key IS NULL OR store_kind = 'global'",
                         name: "memories_origin_project_is_global_provenance"
  end

  def create_memory_revisions_table
    create_table :memory_revisions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :memory_key, null: false
      t.bigint :revision, null: false
      t.string :kind, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.string :lifecycle, null: false
      t.string :authority, null: false
      t.string :author_event_key, null: false
      t.string :author_agent_key
      # Applicability conditions; required and non-empty on global records.
      t.jsonb :applicability, null: false, default: {}
      t.text :rationale
      t.text :tradeoffs
      t.boolean :mandatory, null: false, default: false
      t.string :availability, null: false, default: "available"
      t.column :valid_from, :timestamptz, null: false
      t.column :valid_until, :timestamptz
      t.column :redacted_at, :timestamptz
      t.column :recorded_at, :timestamptz, null: false, default: -> { "now()" }
    end
  end

  def add_memory_revision_indexes_and_foreign_keys
    # Referenced key of the deferred head foreign key and of memory_evidence;
    # its leftmost column also serves the memory_key foreign key.
    add_index :memory_revisions, %i[memory_key revision], unique: true,
                                 name: "index_memory_revisions_on_memory_key_and_revision"
    add_index :memory_revisions, :author_event_key
    add_index :memory_revisions, :author_agent_key
    add_index :memory_revisions, %i[lifecycle valid_from],
              name: "index_memory_revisions_on_lifecycle_and_valid_from"

    add_foreign_key :memory_revisions, :memories, column: :memory_key, primary_key: :memory_key,
                                                  name: "fk_memory_revisions_memory_key"
    add_foreign_key :memory_revisions, :events, column: :author_event_key,
                                                primary_key: :event_key,
                                                name: "fk_memory_revisions_author_event_key"
    add_foreign_key :memory_revisions, :agents, column: :author_agent_key,
                                                primary_key: :agent_key,
                                                name: "fk_memory_revisions_author_agent_key"
  end

  def add_memory_revision_constraints
    add_check_constraint :memory_revisions, "revision >= 1",
                         name: "memory_revisions_revision_positive"
    add_check_constraint :memory_revisions,
                         "kind IN ('decision', 'constraint', 'correction', 'attempt', " \
                         "'observation', 'procedure', 'task_checkpoint')",
                         name: "memory_revisions_kind_valid"
    add_check_constraint :memory_revisions,
                         "lifecycle IN ('proposed', 'active', 'superseded', 'retracted')",
                         name: "memory_revisions_lifecycle_valid"
    add_check_constraint :memory_revisions,
                         "authority IN ('user', 'assistant', 'tool', 'system', 'imported')",
                         name: "memory_revisions_authority_valid"
    add_check_constraint :memory_revisions,
                         "availability IN ('available', 'redacted', 'missing', 'expired')",
                         name: "memory_revisions_availability_valid"
    add_check_constraint :memory_revisions, "valid_until IS NULL OR valid_until > valid_from",
                         name: "memory_revisions_valid_interval_ordered"
    add_check_constraint :memory_revisions, "jsonb_typeof(applicability) = 'object'",
                         name: "memory_revisions_applicability_is_object"
  end

  # Content is required while the revision is available; privacy redaction is the
  # only path that empties it, and it leaves the row in place (Plan §5.3).
  def add_memory_revision_redaction_constraints
    add_check_constraint :memory_revisions,
                         "availability <> 'available' OR (btrim(title) <> '' AND btrim(body) <> '')",
                         name: "memory_revisions_content_present_when_available"
    add_check_constraint :memory_revisions,
                         "(availability = 'available' AND redacted_at IS NULL) " \
                         "OR (availability <> 'available' AND redacted_at IS NOT NULL)",
                         name: "memory_revisions_redacted_at_matches_availability"
  end

  # The head points at one of its own revisions. DEFERRABLE INITIALLY DEFERRED is
  # what lets the head and revision 1 be inserted in either order inside one
  # transaction while still forbidding a committed head with no revision.
  def link_head_to_revision
    add_foreign_key :memories, :memory_revisions,
                    column: %i[memory_key current_revision],
                    primary_key: %i[memory_key revision],
                    deferrable: :deferred,
                    name: "fk_memories_current_revision"
  end

  def create_memory_evidence_table
    create_table :memory_evidence, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :memory_key, null: false
      t.bigint :revision, null: false
      t.string :evidence_key, null: false
      t.string :relation, null: false
      t.column :recorded_at, :timestamptz, null: false, default: -> { "now()" }
    end

    add_index :memory_evidence, %i[memory_key revision evidence_key relation], unique: true,
                                name: "index_memory_evidence_on_revision_and_evidence"
    add_index :memory_evidence, :evidence_key, name: "memory_evidence_reverse"

    add_foreign_key :memory_evidence, :memory_revisions,
                    column: %i[memory_key revision],
                    primary_key: %i[memory_key revision],
                    name: "fk_memory_evidence_revision"
    add_foreign_key :memory_evidence, :evidence, column: :evidence_key,
                                                 primary_key: :evidence_key,
                                                 name: "fk_memory_evidence_evidence_key"

    add_check_constraint :memory_evidence, "relation IN ('supports', 'contradicts', 'context')",
                         name: "memory_evidence_relation_valid"
    add_check_constraint :memory_evidence, "revision >= 1",
                         name: "memory_evidence_revision_positive"
  end

  def install_append_only_guard
    reversible do |direction|
      direction.up do
        create_append_only_function
        create_append_only_trigger
      end
      direction.down do
        execute "DROP TRIGGER IF EXISTS memory_revisions_append_only ON memory_revisions;"
        execute "DROP FUNCTION IF EXISTS kioku_memory_revisions_append_only();"
      end
    end
  end

  # Revisions are append-only (Plan invariant 4). Corrections append a new
  # revision; only privacy redaction may touch a stored one, and it may only move
  # availability away from 'available' and empty the content columns.
  def create_append_only_function
    execute(<<~SQL)
      CREATE FUNCTION kioku_memory_revisions_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $function$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'memory_revisions is append-only: revision % of % cannot be deleted',
            OLD.revision, OLD.memory_key USING ERRCODE = '23514';
        END IF;

        IF OLD.availability <> 'available' OR NEW.availability = 'available' THEN
          RAISE EXCEPTION 'memory_revisions is append-only: revision % of % cannot be updated',
            OLD.revision, OLD.memory_key USING ERRCODE = '23514';
        END IF;

        IF (to_jsonb(NEW) - 'title' - 'body' - 'availability' - 'redacted_at')
             IS DISTINCT FROM
           (to_jsonb(OLD) - 'title' - 'body' - 'availability' - 'redacted_at') THEN
          RAISE EXCEPTION 'memory_revisions revision % of % is immutable outside privacy redaction',
            OLD.revision, OLD.memory_key USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $function$;
    SQL
  end

  def create_append_only_trigger
    execute(<<~SQL)
      CREATE TRIGGER memory_revisions_append_only
      BEFORE UPDATE OR DELETE ON memory_revisions
      FOR EACH ROW EXECUTE FUNCTION kioku_memory_revisions_append_only();
    SQL
  end
end
