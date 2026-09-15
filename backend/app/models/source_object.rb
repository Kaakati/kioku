# frozen_string_literal: true

# One retained object: the bytes an evidence reference points at (research
# Appendix A, plan 5.2 "Event and evidence", plan 7.1 step 3).
#
# `availability` is physical object-store state, not the per-reference delivery
# label. Invariant 3 is decided on it: an evidence reference may commit as
# available only while the bytes it names are retained.
class SourceObject < ApplicationRecord
  self.table_name = "source_objects"
  self.primary_key = "object_key"

  AVAILABILITY = %w[available purged].freeze

  has_many :evidence_records, class_name: "Evidence", foreign_key: :object_key,
                              primary_key: :object_key, inverse_of: false,
                              dependent: :restrict_with_exception

  validates :availability, inclusion: { in: AVAILABILITY }
  validates :byte_length, numericality: { greater_than_or_equal_to: 0, only_integer: true }
end
