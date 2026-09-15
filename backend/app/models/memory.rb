# frozen_string_literal: true

# The stable head of one remembered statement (research Appendix A, plan 5.2
# "Memory").
#
# The head names its current revision explicitly. Delivery joins on
# `r.revision = m.current_revision`, never on MAX(revision), because retracting
# the newest revision leaves the head pointing at an earlier one and a
# highest-number read would resurrect the retraction.
class Memory < ApplicationRecord
  STORE_KINDS = %w[global project].freeze
  # Plan 1.3's four global engineering categories.
  CATEGORIES = %w[coding_style engineering_decision architecture preferred_library].freeze

  belongs_to :project, foreign_key: :project_key, primary_key: :project_key,
                       inverse_of: :memories, optional: true

  has_many :revisions, class_name: "MemoryRevision", foreign_key: :memory_key,
                       primary_key: :memory_key, inverse_of: :memory,
                       dependent: :restrict_with_exception

  has_one :head_revision, ->(memory) { where(revision: memory.current_revision) },
          class_name: "MemoryRevision", foreign_key: :memory_key,
          primary_key: :memory_key, inverse_of: :memory,
          dependent: :restrict_with_exception

  validates :store_kind, inclusion: { in: STORE_KINDS }
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true
  validates :current_revision,
            numericality: { greater_than_or_equal_to: 1, only_integer: true }
  validate :ownership_names_exactly_one_destination

  private

  # Plan 5.2, verbatim: "Memory ownership requires exactly one destination:
  # store_kind='global' with no owner project, or store_kind='project' with a
  # non-null project_key ... never interpret a missing project ID as permission
  # to fall back to global."
  def ownership_names_exactly_one_destination
    case store_kind
    when "global"
      return if project_key.blank?

      errors.add(:project_key, "must be absent on a global record")
    when "project"
      return if project_key.present?

      errors.add(:project_key, "is required on a project-owned record")
    end
  end
end
