# frozen_string_literal: true

# One ownership destination per record (Plan §1.1, §5.2).
#
# A record is project-owned (`store_kind = "project"` with a `project_key`) or
# global (`store_kind = "global"` with no owning project). It cannot be both and
# cannot be neither. The database enforces this with a CHECK constraint named
# "<table>_single_ownership_destination"; this concern is the matching validation
# so the failure surfaces as a validation error rather than a StatementInvalid.
#
# A missing project_key is never permission to fall back to the global store.
module OwnershipDestination
  extend ActiveSupport::Concern

  STORE_KINDS = %w[project global].freeze

  included do
    belongs_to :project, primary_key: :project_key, foreign_key: :project_key, optional: true

    validates :store_kind, presence: true, inclusion: { in: STORE_KINDS }
    validate :ownership_destination_is_exclusive

    scope :owned_by_project, ->(project_key) { where(store_kind: "project", project_key:) }
    scope :global, -> { where(store_kind: "global") }
  end

  def project_owned?
    store_kind == "project"
  end

  def global?
    store_kind == "global"
  end

  private

  def ownership_destination_is_exclusive
    return if project_owned? && project_key.present?
    return if global? && project_key.nil?

    errors.add(:project_key,
               "must name a project when store_kind is \"project\" and be absent when it is \"global\"")
  end
end
