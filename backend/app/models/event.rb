# frozen_string_literal: true

# An immutable capture event (Research Appendix A `events`).
#
# (installation_id, producer_key, producer_epoch, producer_sequence) is the
# deduplication key that makes host spool replay safe. Attribution is never
# inferred from timing or process id: when the join cannot be established the
# event stays `unresolved` with no agent_key.
class Event < ApplicationRecord
  ATTRIBUTION_STATES = %w[resolved unresolved not_applicable].freeze
  ORIGIN_ROLES = %w[user assistant tool system imported].freeze

  include OwnershipDestination

  belongs_to :installation
  belongs_to :session, primary_key: :session_key, foreign_key: :session_key, optional: true
  belongs_to :agent, primary_key: :agent_key, foreign_key: :agent_key, optional: true
  belongs_to :payload_object, class_name: "SourceObject", primary_key: :object_key,
                              foreign_key: :payload_object_key, optional: true
  belongs_to :origin_project, class_name: "Project", primary_key: :project_key,
                              foreign_key: :origin_project_key, optional: true

  has_many :evidence_records, class_name: "Evidence", primary_key: :event_key,
                              foreign_key: :origin_event_key, dependent: :restrict_with_error
  has_many :outbox_events, primary_key: :event_key, foreign_key: :event_key,
                           dependent: :restrict_with_error

  validates :event_key, presence: true, uniqueness: true
  validates :producer_key, :producer_epoch, :event_type, presence: true
  validates :producer_sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :producer_sequence,
            uniqueness: { scope: %i[installation_id producer_key producer_epoch] }
  validates :attribution_state, inclusion: { in: ATTRIBUTION_STATES }
  validates :origin_role, inclusion: { in: ORIGIN_ROLES }
  validates :observed_at, presence: true
  validate :attribution_state_matches_agent
  validate :origin_project_is_global_provenance

  def attributed?
    attribution_state == "resolved"
  end

  private

  def attribution_state_matches_agent
    return if attribution_state == "resolved" && agent_key.present?
    return if %w[unresolved not_applicable].include?(attribution_state) && agent_key.nil?

    errors.add(:attribution_state, "must be \"resolved\" exactly when an agent is named")
  end

  def origin_project_is_global_provenance
    return if origin_project_key.nil? || global?

    errors.add(:origin_project_key, "is provenance for global records only")
  end
end
