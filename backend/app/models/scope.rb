# frozen_string_literal: true

# An authorization scope: the ownership anchor evidence and memories are filed
# under (Research Appendix A; Plan §5.2). Its own `store_kind`/`project_key` pair
# must match that of everything filed under it, which the composite foreign keys
# "fk_*_scope_store_kind" and "fk_*_scope_ownership" enforce.
class Scope < ApplicationRecord
  include OwnershipDestination

  PROJECT_KINDS = %w[project repository worktree task].freeze
  GLOBAL_KINDS = %w[global installation].freeze
  KINDS = (GLOBAL_KINDS + PROJECT_KINDS).freeze

  belongs_to :installation

  has_many :evidence_records, class_name: "Evidence", primary_key: :scope_key,
                              foreign_key: :scope_key, dependent: :restrict_with_error
  has_many :memories, primary_key: :scope_key, foreign_key: :scope_key,
                      dependent: :restrict_with_error

  validates :scope_key, presence: true, uniqueness: true
  validates :subject_key, presence: true
  validates :scope_kind, inclusion: { in: KINDS }
  validates :subject_key, uniqueness: { scope: %i[installation_id scope_kind] }
  validate :scope_kind_matches_store_kind

  private

  # The installation catalog is administrative rather than project-owned, so it
  # sits on the global side of the discriminator. Retrieval still filters on
  # scope_kind and does not treat it as global engineering guidance.
  def scope_kind_matches_store_kind
    return if PROJECT_KINDS.include?(scope_kind) && project_owned?
    return if GLOBAL_KINDS.include?(scope_kind) && global?

    errors.add(:scope_kind, "#{scope_kind.inspect} is not compatible with store_kind #{store_kind.inspect}")
  end
end
