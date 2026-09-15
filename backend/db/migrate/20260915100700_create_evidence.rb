# frozen_string_literal: true

# Evidence references (Research Appendix A `evidence`, plus Plan §5.2 ownership).
#
# Evidence points at canonical events and retained objects rather than at
# disposable index rows, and carries its own scope and ownership so a shared
# physical object never leaks across projects.
class CreateEvidence < ActiveRecord::Migration[8.1]
  def change
    create_evidence_table
    add_evidence_indexes
    add_evidence_foreign_keys
    add_evidence_constraints
  end

  private

  def create_evidence_table
    create_table :evidence, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :evidence_key, null: false
      t.string :scope_key, null: false
      t.string :store_kind, null: false
      t.string :project_key
      t.string :evidence_kind, null: false
      t.string :origin_event_key
      t.string :object_key
      # Versioned application type (repository/worktree/path/content hash, …).
      # It is data, never an instruction.
      t.jsonb :source_anchor, null: false
      t.string :availability, null: false, default: "available"
      t.column :recorded_at, :timestamptz, null: false, default: -> { "now()" }
    end
  end

  def add_evidence_indexes
    add_index :evidence, :evidence_key, unique: true
    # Leftmost prefixes of this index serve both composite foreign keys below.
    add_index :evidence, %i[scope_key store_kind project_key],
              name: "index_evidence_on_ownership_triple"
    add_index :evidence, :origin_event_key
    add_index :evidence, :object_key
    add_index :evidence, :project_key
  end

  def add_evidence_foreign_keys
    add_foreign_key :evidence, :events, column: :origin_event_key, primary_key: :event_key,
                                        name: "fk_evidence_origin_event_key"
    add_foreign_key :evidence, :source_objects, column: :object_key, primary_key: :object_key,
                                                name: "fk_evidence_object_key"
    add_foreign_key :evidence, :projects, column: :project_key, primary_key: :project_key,
                                          name: "fk_evidence_project_key"

    # Owner scope must match the record's own ownership. The two-column key
    # covers global rows, where MATCH SIMPLE skips the three-column key because
    # project_key is NULL.
    add_foreign_key :evidence, :scopes, column: %i[scope_key store_kind],
                                        primary_key: %i[scope_key store_kind],
                                        name: "fk_evidence_scope_store_kind"
    add_foreign_key :evidence, :scopes, column: %i[scope_key store_kind project_key],
                                        primary_key: %i[scope_key store_kind project_key],
                                        name: "fk_evidence_scope_ownership"
  end

  def add_evidence_constraints
    add_check_constraint :evidence, "btrim(evidence_key) <> '' AND btrim(evidence_kind) <> ''",
                         name: "evidence_keys_present"
    add_check_constraint :evidence, "jsonb_typeof(source_anchor) = 'object'",
                         name: "evidence_source_anchor_is_object"
    add_check_constraint :evidence,
                         "availability IN ('available', 'redacted', 'missing', 'expired')",
                         name: "evidence_availability_valid"

    # Evidence must be backed by something canonical.
    add_check_constraint :evidence, "origin_event_key IS NOT NULL OR object_key IS NOT NULL",
                         name: "evidence_backing_reference_present"

    add_check_constraint :evidence, "store_kind IN ('project', 'global')",
                         name: "evidence_store_kind_valid"
    add_check_constraint :evidence,
                         "(store_kind = 'project' AND project_key IS NOT NULL) " \
                         "OR (store_kind = 'global' AND project_key IS NULL)",
                         name: "evidence_single_ownership_destination"
  end
end
