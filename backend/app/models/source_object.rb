# frozen_string_literal: true

# Committed metadata for a retained object (Plan §5.3). The bytes live under
# KIOKU_OBJECT_ROOT; this row is what makes an evidence handle available, and it
# is written only after the bytes are durable (Plan invariant 3).
#
# `content_hash` is unique because content addressing deduplicates bytes. Scope
# and retention live on `evidence`, so a raw hash grants no access by itself.
class SourceObject < ApplicationRecord
  AVAILABILITIES = %w[available purged].freeze

  has_many :evidence_records, class_name: "Evidence", primary_key: :object_key,
                              foreign_key: :object_key, dependent: :restrict_with_error

  validates :object_key, presence: true, uniqueness: true
  validates :content_hash, presence: true, uniqueness: true
  validates :hash_algorithm, presence: true
  validates :byte_length, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :availability, inclusion: { in: AVAILABILITIES }
  validate :purged_at_matches_availability

  def available?
    availability == "available"
  end

  private

  def purged_at_matches_availability
    return if availability == "purged" && purged_at.present?
    return if availability == "available" && purged_at.nil?

    errors.add(:purged_at, "must be set exactly when the object is purged")
  end
end
