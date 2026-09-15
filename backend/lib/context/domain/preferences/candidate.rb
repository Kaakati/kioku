# frozen_string_literal: true

module Context
  module Domain
    module Preferences
      # A global engineering record being considered for a project.
      #
      # conflict_key is declared, never inferred. The core recognizes a
      # conflict between two records only when they have been put in the same
      # declared conflict group; it does not decide from the text of two
      # records that they disagree, and it never resolves a disagreement it
      # merely guessed at.
      class Candidate < Data.define(
        :memory_key, :revision, :category, :authority, :lifecycle, :mandatory,
        :applicability, :conflict_key, :valid_from, :valid_until, :title, :body,
        :has_open_dispute, :recorded_at
      )
        def initialize(memory_key:, revision:, category:, authority:, lifecycle:, applicability:,
                       mandatory: false, conflict_key: nil, valid_from: nil, valid_until: nil,
                       title: nil, body: nil, has_open_dispute: false, recorded_at: nil)
          super
        end

        # Only active records govern. A proposed record stays discoverable but
        # is not effective policy, which is what keeps repeated assistant
        # inference from becoming a user preference.
        def governing_lifecycle? = lifecycle == "active"

        def valid_at?(now)
          return false if valid_from && valid_from > now

          valid_until.nil? || valid_until > now
        end

        def applies_to?(stack_profile)
          applicability.nil? || applicability.matches?(stack_profile)
        end

        def conflict_group = conflict_key.nil? ? nil : [category, conflict_key]
      end
    end
  end
end
