# frozen_string_literal: true

# The derived lexical projection of a memory's current revision (plan 5.1
# "derived code/search tables", plan 5.4 "Search document lifecycle").
#
# Derived, not canonical: it is rebuildable from memories and memory_revisions,
# and it is published in the same transaction as the canonical change it
# projects. There is one current document per memory, so a later revision
# replaces the row rather than adding one.
class MemorySearchDocument < ApplicationRecord
  STORE_KINDS = %w[global project].freeze

  # The same four values as memory_revisions.lifecycle: this row describes a
  # revision, and the retrieval gate reads it here rather than joining, so a
  # value the revision table cannot hold would describe a state that does not
  # exist.
  LIFECYCLES = %w[proposed active superseded retracted].freeze

  validates :memory_key, presence: true, uniqueness: true
  validates :store_kind, inclusion: { in: STORE_KINDS }
  validates :lifecycle, inclusion: { in: LIFECYCLES }
  validates :title, :body, presence: true
  validate :ownership_names_exactly_one_destination

  private

  # The scope gate filters on these two columns, so a document that names both
  # owners or neither would be visible from the wrong scope or from none.
  def ownership_names_exactly_one_destination
    case store_kind
    when "global"
      return if project_key.blank?

      errors.add(:project_key, "must be absent on a global document")
    when "project"
      return if project_key.present?

      errors.add(:project_key, "is required on a project-owned document")
    end
  end
end
