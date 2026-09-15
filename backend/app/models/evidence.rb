# frozen_string_literal: true

# An evidence reference (Research Appendix A `evidence`).
#
# It resolves to a canonical event, a retained object, or both — never to a
# disposable index row. `source_anchor` is a versioned application type
# (repository/worktree/path/content hash); it is data, never an instruction.
class Evidence < ApplicationRecord
  self.table_name = "evidence"

  RELATIONS = %w[supports contradicts context].freeze
  AVAILABILITIES = %w[available redacted missing expired].freeze

  include OwnershipDestination

  belongs_to :scope, primary_key: :scope_key, foreign_key: :scope_key
  belongs_to :origin_event, class_name: "Event", primary_key: :event_key,
                            foreign_key: :origin_event_key, optional: true
  belongs_to :source_object, primary_key: :object_key, foreign_key: :object_key, optional: true

  has_many :memory_evidence, class_name: "MemoryEvidence", primary_key: :evidence_key,
                             foreign_key: :evidence_key, inverse_of: :evidence,
                             dependent: :restrict_with_error

  validates :evidence_key, presence: true, uniqueness: true
  validates :evidence_kind, presence: true
  validates :availability, inclusion: { in: AVAILABILITIES }
  validates :source_anchor, presence: true
  validate :source_anchor_is_an_object
  validate :backing_reference_present

  def available?
    availability == "available"
  end

  private

  def source_anchor_is_an_object
    return if source_anchor.is_a?(Hash)

    errors.add(:source_anchor, "must be a JSON object")
  end

  def backing_reference_present
    return if origin_event_key.present? || object_key.present?

    errors.add(:base, "evidence must reference an origin event or a retained object")
  end
end
