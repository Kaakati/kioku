# frozen_string_literal: true

# Authorization scopes (Research Appendix A `scopes`, extended by Plan §5.2 with
# explicit `global` and `project` kinds and an ownership discriminator).
#
# A scope is the ownership anchor for evidence and memories. `store_kind` plus
# `project_key` is the single ownership destination: a row is project-owned or
# global, never both and never neither.
class CreateScopes < ActiveRecord::Migration[8.1]
  def change
    create_scopes_table
    add_scope_indexes
    add_scope_constraints
  end

  private

  def create_scopes_table
    create_table :scopes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # The unique (installation_id, scope_kind, subject_key) index below covers
      # this foreign key's leftmost column, so no separate index is created.
      t.references :installation, null: false, type: :uuid, foreign_key: true, index: false
      t.string :scope_key, null: false
      t.string :scope_kind, null: false
      t.string :store_kind, null: false
      t.string :project_key
      t.string :subject_key, null: false
      t.column :created_at, :timestamptz, null: false, default: -> { "now()" }
      t.column :updated_at, :timestamptz, null: false, default: -> { "now()" }
    end
  end

  def add_scope_indexes
    add_index :scopes, :scope_key, unique: true
    add_index :scopes, %i[installation_id scope_kind subject_key], unique: true,
                       name: "index_scopes_on_installation_kind_and_subject"
    add_index :scopes, :project_key

    # Composite referenced keys. Owned records carry (scope_key, store_kind,
    # project_key) and point back here, so an owner can never disagree with the
    # scope it was filed under. Both are needed: PostgreSQL foreign keys use
    # MATCH SIMPLE, so the three-column key is skipped when project_key is NULL
    # (global rows) and the two-column key covers exactly that case.
    add_index :scopes, %i[scope_key store_kind], unique: true,
                       name: "index_scopes_on_scope_key_and_store_kind"
    add_index :scopes, %i[scope_key store_kind project_key], unique: true,
                       name: "index_scopes_on_ownership_triple"

    add_foreign_key :scopes, :projects, column: :project_key, primary_key: :project_key,
                                        name: "fk_scopes_project_key"
  end

  def add_scope_constraints
    add_check_constraint :scopes, "btrim(scope_key) <> '' AND btrim(subject_key) <> ''",
                         name: "scopes_keys_present"
    add_check_constraint :scopes,
                         "scope_kind IN ('global', 'installation', 'project', 'repository', 'worktree', 'task')",
                         name: "scopes_scope_kind_valid"
    add_check_constraint :scopes, "store_kind IN ('project', 'global')",
                         name: "scopes_store_kind_valid"

    # Exactly one ownership destination (Plan §5.2). A missing project_key is
    # never permission to fall back to the global store.
    add_check_constraint :scopes,
                         "(store_kind = 'project' AND project_key IS NOT NULL) " \
                         "OR (store_kind = 'global' AND project_key IS NULL)",
                         name: "scopes_single_ownership_destination"

    # The installation catalog is administrative rather than project-owned, so it
    # sits on the global side of the discriminator; retrieval still filters on
    # scope_kind and does not treat it as global engineering guidance.
    add_check_constraint :scopes,
                         "(scope_kind IN ('project', 'repository', 'worktree', 'task') AND store_kind = 'project') " \
                         "OR (scope_kind IN ('global', 'installation') AND store_kind = 'global')",
                         name: "scopes_kind_matches_store_kind"
  end
end
