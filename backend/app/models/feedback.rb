# frozen_string_literal: true

# A dispute, usefulness or irrelevance signal recorded against one exact memory
# revision (research Appendix A, contract context_feedback).
#
# An open dispute suppresses automatic confident delivery of the revision it
# names, which is why it is keyed on (memory_key, revision) and never on the
# head: a correction must not inherit the objection to the statement it corrects,
# and the objection must not be silently retired by one.
class Feedback < ApplicationRecord
  self.table_name = "feedback"

  ACTIONS = %w[dispute useful irrelevant].freeze
  DISPOSITIONS = %w[open resolved withdrawn].freeze

  belongs_to :memory_revision, foreign_key: %i[memory_key revision],
                               inverse_of: :feedbacks

  validates :action, inclusion: { in: ACTIONS }
  validates :disposition, inclusion: { in: DISPOSITIONS }
  validates :reason, presence: true
end
