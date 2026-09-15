# frozen_string_literal: true

# A coding product or workspace: the ownership boundary for operational history
# (plan 1.1, plan 5.2 "Project", plan invariant 11).
class Project < ApplicationRecord
  LIFECYCLES = %w[active archived].freeze

  # The memories this project OWNS. A global record derived from this project
  # carries origin_project_key instead — provenance, not ownership (plan 5.2) —
  # so deleting or archiving a project cannot take an independent global
  # preference with it (plan 5.3).
  has_many :memories, foreign_key: :project_key, primary_key: :project_key,
                      inverse_of: :project, dependent: :restrict_with_exception

  validates :display_name, presence: true
  validates :lifecycle, inclusion: { in: LIFECYCLES }
end
