# frozen_string_literal: true

# A coding product or workspace (Plan §1.1). Identity is the registered
# `project_key`; it is independent of chat, agent, branch or checkout, and is
# never derived from a filesystem path. Every project-owned row carries it.
class Project < ApplicationRecord
  LIFECYCLES = %w[active archived].freeze

  belongs_to :installation

  has_many :sessions, primary_key: :project_key, foreign_key: :project_key,
                      dependent: :restrict_with_error
  has_many :events, primary_key: :project_key, foreign_key: :project_key,
                    dependent: :restrict_with_error
  has_many :scopes, primary_key: :project_key, foreign_key: :project_key,
                    dependent: :restrict_with_error
  has_many :memories, primary_key: :project_key, foreign_key: :project_key,
                      dependent: :restrict_with_error

  validates :project_key, presence: true, uniqueness: true
  validates :display_name, presence: true
  validates :lifecycle, inclusion: { in: LIFECYCLES }
  validates :configuration_revision,
            numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :policy_generation, :deletion_epoch,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :active, -> { where(lifecycle: "active") }

  # Archiving preserves a project's memory but excludes it from active-project
  # selection by default (Plan §5.3).
  def archived?
    lifecycle == "archived"
  end
end
