# frozen_string_literal: true

# An authorization scope: the installation-wide global store, or one registered
# project (plan 5.2 "Installation and scope", research Appendix A).
#
# Plan 5.2: "never interpret a missing project ID as permission to fall back to
# global". The database enforces that with two check constraints; the same rule
# is stated here so a save that would violate it fails before it reaches them.
class Scope < ApplicationRecord
  KINDS = %w[global project installation repository worktree task].freeze

  belongs_to :project, foreign_key: :project_key, primary_key: :project_key,
                       inverse_of: false, optional: true

  validates :scope_kind, inclusion: { in: KINDS }
  validates :subject_key, presence: true
  validate :ownership_matches_the_scope_kind

  private

  def ownership_matches_the_scope_kind
    case scope_kind
    when "project"
      return if project_key.present?

      errors.add(:project_key, "is required on a project scope")
    when "global"
      return if project_key.blank?

      errors.add(:project_key, "must be absent on a global scope")
    end
  end
end
