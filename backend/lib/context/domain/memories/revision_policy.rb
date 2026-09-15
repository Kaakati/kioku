# frozen_string_literal: true

module Context
  module Domain
    module Memories
      # Revisions are immutable and append-only. A write either creates a
      # memory at revision 1 or appends the revision after the head the writer
      # says it saw. Anything else is a conflict, and a conflict writes nothing
      # (Plan invariant 4).
      module RevisionPolicy
        FIRST_REVISION = 1

        module_function

        # head_revision is the locked current head, or nil when no memory
        # exists under that key.
        def next_revision(head_revision:, expected_revision:, target_key: nil)
          return creating_revision(expected_revision, target_key) if head_revision.nil?

          conflict!(head_revision, target_key) if expected_revision.nil?
          conflict!(head_revision, target_key) unless expected_revision == head_revision
          head_revision + 1
        end

        def creating_revision(expected_revision, target_key)
          conflict!(nil, target_key) unless expected_revision.nil?

          FIRST_REVISION
        end

        # Carries the current revision so the caller can re-read and retry
        # against what is actually there.
        def conflict!(current_revision, target_key)
          raise Errors::RevisionConflict.new(
            details: { current_revision: current_revision, current_head: current_revision, target_key: target_key }
          )
        end
      end
    end
  end
end
