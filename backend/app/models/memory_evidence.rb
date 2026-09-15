# frozen_string_literal: true

# The link between one exact memory revision and one piece of evidence
# (Research Appendix A `memory_evidence`).
#
# The core requires at least one eligible link before a memory-save transaction
# commits; that rule belongs to the write use case, not to this model. What the
# model guarantees is that the link names a revision that exists and states the
# relation explicitly, so contradicting evidence stays attached to the claim it
# contradicts instead of being dropped.
class MemoryEvidence < ApplicationRecord
  self.table_name = "memory_evidence"

  RELATIONS = %w[supports contradicts context].freeze

  belongs_to :memory, primary_key: :memory_key, foreign_key: :memory_key
  belongs_to :evidence, primary_key: :evidence_key, foreign_key: :evidence_key,
                        inverse_of: :memory_evidence

  validates :revision, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :relation, inclusion: { in: RELATIONS }
  validates :evidence_key, uniqueness: { scope: %i[memory_key revision relation] }

  scope :supporting, -> { where(relation: "supports") }
  scope :contradicting, -> { where(relation: "contradicts") }

  # The revision this link is attached to. A lookup rather than an association
  # because the join is on the composite (memory_key, revision).
  def memory_revision
    MemoryRevision.find_by(memory_key:, revision:)
  end
end
