# frozen_string_literal: true

# The stable head of one memory (Research Appendix A `memories`; Plan §1.1, §5.2).
#
# Ownership has exactly one destination: a global engineering record carries a
# category and no owning project, a project memory carries a project_key and no
# category. `origin_project_key` is separate provenance on global records and
# never makes them project-owned.
#
# The head and its revision 1 are inserted in one transaction; the deferred
# foreign key "fk_memories_current_revision" is what permits that while still
# forbidding a committed head that points at no revision.
class Memory < ApplicationRecord
  GLOBAL_CATEGORIES = %w[coding_style engineering_decision architecture preferred_library].freeze

  include OwnershipDestination

  belongs_to :scope, primary_key: :scope_key, foreign_key: :scope_key
  belongs_to :origin_project, class_name: "Project", primary_key: :project_key,
                              foreign_key: :origin_project_key, optional: true

  has_many :revisions, class_name: "MemoryRevision", primary_key: :memory_key,
                       foreign_key: :memory_key, inverse_of: :memory,
                       dependent: :restrict_with_error

  validates :memory_key, presence: true, uniqueness: true
  validates :current_revision, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :deletion_epoch, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :category, inclusion: { in: GLOBAL_CATEGORIES }, allow_nil: true
  validate :category_matches_store_kind
  validate :origin_project_is_global_provenance

  # The revision the head currently points at. Older revisions stay historical
  # rather than being rewritten (Plan invariant 4).
  def head
    revisions.find_by(revision: current_revision)
  end

  private

  def category_matches_store_kind
    return if global? && category.present?
    return if project_owned? && category.nil?

    errors.add(:category, "is required on global records and not permitted on project memories")
  end

  def origin_project_is_global_provenance
    return if origin_project_key.nil? || global?

    errors.add(:origin_project_key, "is provenance for global records only")
  end
end
