# frozen_string_literal: true

# A Claude Code session, identified locally and joined to the provider's own
# session id (research Appendix A, plan 5.2 "Session and agent").
class Session < ApplicationRecord
  has_many :agents, foreign_key: :session_key, primary_key: :session_key,
                    inverse_of: :session, dependent: :restrict_with_exception
end
