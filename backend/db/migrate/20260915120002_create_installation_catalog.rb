# frozen_string_literal: true

# The installation catalog: who this Kioku belongs to, which projects it knows
# about, and which authorization scopes exist (plan 5.1 "installation catalog",
# plan 5.2 "Installation and scope" / "Project").
#
# Translated from research Appendix A, not copied: `installation_id` becomes
# `installation_key` so storage handles match the `*_key` names the frozen tool
# contract uses on the wire, and Appendix A's `scope_kind` gains 'global' and
# 'project' (plan 5.2, plan 1.1).
class CreateInstallationCatalog < ActiveRecord::Migration[8.1]
  # Appendix A's four scope kinds plus the two the project/global split adds.
  SCOPE_KINDS = %w[global project installation repository worktree task].freeze

  # Plan 5.3: "Archiving a project preserves its memory but excludes it from
  # active-project selection by default."
  PROJECT_LIFECYCLES = %w[active archived].freeze

  def change
    # An installation has no attributes of its own yet; it is the identity every
    # session, scope and event hangs from (Appendix A).
    create_table :installations, id: :text, primary_key: :installation_key

    create_projects
    create_scopes
  end

  private

  def create_projects
    # Plan 1.2: a project registers a stable key and a display name. Plan 5.2:
    # "no identity derived only from a path" — the key is assigned, never
    # inferred from a checkout location.
    create_table :projects, id: :text, primary_key: :project_key do |t|
      t.text :display_name, null: false
      t.text :lifecycle, null: false, default: "active"
    end

    add_check_constraint :projects,
                         "lifecycle IN (#{quoted(PROJECT_LIFECYCLES)})",
                         name: "projects_lifecycle_vocabulary"
  end

  def create_scopes
    create_table :scopes, id: :text, primary_key: :scope_key do |t|
      t.text :installation_key, null: false
      t.text :scope_kind, null: false
      t.text :project_key
      t.text :subject_key, null: false
    end

    add_index :scopes, %i[installation_key scope_kind subject_key], unique: true,
                                                                    name: "scopes_subject_unique"
    add_index :scopes, :project_key
    add_foreign_key :scopes, :installations, column: :installation_key,
                                             primary_key: :installation_key
    add_foreign_key :scopes, :projects, column: :project_key, primary_key: :project_key

    add_scope_check_constraints
  end

  # Plan 5.2: "Enforce the discriminator, project foreign keys and matching owner
  # scope in storage constraints plus core validation; never interpret a missing
  # project ID as permission to fall back to global." A project scope with no
  # project authorizes nothing in particular; a global scope that names one is a
  # project's private history wearing the installation-wide label.
  def add_scope_check_constraints
    add_check_constraint :scopes,
                         "scope_kind IN (#{quoted(SCOPE_KINDS)})",
                         name: "scopes_kind_vocabulary"
    add_check_constraint :scopes,
                         "scope_kind <> 'project' OR project_key IS NOT NULL",
                         name: "scopes_project_requires_owner"
    add_check_constraint :scopes,
                         "scope_kind <> 'global' OR project_key IS NULL",
                         name: "scopes_global_owns_no_project"
  end

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end
end
