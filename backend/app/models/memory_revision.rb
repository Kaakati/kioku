# frozen_string_literal: true

# One immutable memory revision (Research Appendix A `memory_revisions`).
#
# Corrections append a new revision; stored revisions are never edited. The
# database trigger "memory_revisions_append_only" is the authority — it refuses
# every DELETE and every UPDATE except a privacy redaction. `readonly?` below
# simply keeps Active Record from issuing an UPDATE that is certain to fail.
class MemoryRevision < ApplicationRecord
  KINDS = %w[decision constraint correction attempt observation procedure task_checkpoint].freeze
  LIFECYCLES = %w[proposed active superseded retracted].freeze
  AUTHORITIES = %w[user assistant tool system imported].freeze
  AVAILABILITIES = %w[available redacted missing expired].freeze
  REDACTED_AVAILABILITIES = (AVAILABILITIES - %w[available]).freeze

  TITLE_MAX = 200
  BODY_MAX = 16_384

  belongs_to :memory, primary_key: :memory_key, foreign_key: :memory_key, inverse_of: :revisions
  belongs_to :author_event, class_name: "Event", primary_key: :event_key,
                            foreign_key: :author_event_key
  belongs_to :author_agent, class_name: "Agent", primary_key: :agent_key,
                            foreign_key: :author_agent_key, optional: true

  validates :revision, numericality: { only_integer: true, greater_than_or_equal_to: 1 },
                       uniqueness: { scope: :memory_key }
  validates :kind, inclusion: { in: KINDS }
  validates :lifecycle, inclusion: { in: LIFECYCLES }
  validates :authority, inclusion: { in: AUTHORITIES }
  validates :availability, inclusion: { in: AVAILABILITIES }
  validates :valid_from, presence: true
  validates :title, presence: true, length: { maximum: TITLE_MAX }, if: :available?
  validates :body, presence: true, length: { maximum: BODY_MAX }, if: :available?
  validate :valid_interval_ordered

  scope :available, -> { where(availability: "available") }

  def available?
    availability == "available"
  end

  def readonly?
    persisted?
  end

  # The evidence links for this exact revision. A plain relation rather than an
  # association because the join is on the composite (memory_key, revision).
  def evidence_links
    MemoryEvidence.where(memory_key:, revision:)
  end

  # Privacy deletion is a separate lifecycle from supersession (Plan §5.3): the
  # revision stays in place so replay cannot resurrect it, but its content goes.
  # A relation update is used deliberately, because the record is readonly.
  def redact!(availability: "redacted", at: Time.current)
    unless REDACTED_AVAILABILITIES.include?(availability)
      raise ArgumentError, "unsupported redaction availability: #{availability.inspect}"
    end

    redacted = self.class.where(id: id, availability: "available")
                   .update_all(title: "", body: "", availability:, redacted_at: at)
    reload
    redacted == 1
  end

  private

  def valid_interval_ordered
    return if valid_until.nil? || valid_from.nil? || valid_until > valid_from

    errors.add(:valid_until, "must be after valid_from")
  end
end
