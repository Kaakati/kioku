# frozen_string_literal: true

# Installation catalog and project registry (Plan §1.1, §1.2, §5.1, §5.2).
#
# The installation owns the global engineering namespace and its generations.
# A project owns every project-scoped record through a stable `project_key`
# that survives renames and path moves; no identity is derived from a path.
class CreateInstallationsAndProjects < ActiveRecord::Migration[8.1]
  def change
    create_installations
    create_projects
  end

  private

  def create_installations
    create_table :installations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :installation_key, null: false
      t.string :display_name
      # Generation counters reported in the tool envelope's generation_vector.
      t.bigint :canonical_generation, null: false, default: 0
      t.bigint :global_generation, null: false, default: 0
      t.bigint :deletion_epoch, null: false, default: 0
      t.column :created_at, :timestamptz, null: false, default: -> { "now()" }
      t.column :updated_at, :timestamptz, null: false, default: -> { "now()" }
    end

    add_index :installations, :installation_key, unique: true

    add_check_constraint :installations, "btrim(installation_key) <> ''",
                         name: "installations_key_present"
    add_check_constraint :installations,
                         "canonical_generation >= 0 AND global_generation >= 0 AND deletion_epoch >= 0",
                         name: "installations_generations_non_negative"
  end

  def create_projects
    create_table :projects, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :installation, null: false, type: :uuid, foreign_key: true
      t.string :project_key, null: false
      t.string :display_name, null: false
      t.string :lifecycle, null: false, default: "active"
      # Languages, frameworks and platforms used to match applicable global guidance.
      t.jsonb :stack_profile, null: false, default: {}
      t.bigint :configuration_revision, null: false, default: 1
      # An override or stack-profile edit advances this project's policy generation (Plan §5.2).
      t.bigint :policy_generation, null: false, default: 0
      t.bigint :deletion_epoch, null: false, default: 0
      t.column :created_at, :timestamptz, null: false, default: -> { "now()" }
      t.column :updated_at, :timestamptz, null: false, default: -> { "now()" }
    end

    # project_key is the stable ownership key every project-owned row carries, so
    # it is unique installation-wide and is the referenced key of those foreign keys.
    add_index :projects, :project_key, unique: true

    add_project_constraints
  end

  def add_project_constraints
    add_check_constraint :projects, "btrim(project_key) <> ''", name: "projects_key_present"
    add_check_constraint :projects, "lifecycle IN ('active', 'archived')",
                         name: "projects_lifecycle_valid"
    add_check_constraint :projects, "configuration_revision >= 1",
                         name: "projects_configuration_revision_positive"
    add_check_constraint :projects, "policy_generation >= 0 AND deletion_epoch >= 0",
                         name: "projects_generations_non_negative"
    add_check_constraint :projects, "jsonb_typeof(stack_profile) = 'object'",
                         name: "projects_stack_profile_is_object"
  end
end
