# frozen_string_literal: true

# One immutable revision of a memory (research Appendix A, plan invariant 4:
# "Revisions are immutable. Corrections append attributed revisions.").
#
# PostgreSQL holds the guarantee through the append-only trigger. The model
# refuses first so a service never sends a doomed UPDATE inside the short
# transaction that also carries the search projection, the receipt and the outbox
# row (plan 5.1, 7.1 step 5): one statement raising mid-transaction would roll
# back work that had nothing wrong with it.
#
# `readonly?` is true only once the row is persisted, so appending a new revision
# still works — append-only means append-ONLY, not insert-once.
class MemoryRevision < ApplicationRecord
  belongs_to :memory, foreign_key: :memory_key, primary_key: :memory_key,
                      inverse_of: :revisions

  # Keyed on (memory_key, revision) rather than on the memory head: a link that
  # drifted onto the head would let a correction inherit the evidence that
  # supported the statement it corrects.
  has_many :evidence_links, class_name: "MemoryEvidence",
                            foreign_key: %i[memory_key revision],
                            inverse_of: :memory_revision,
                            dependent: :restrict_with_exception

  has_many :evidence, through: :evidence_links

  # Contract context_feedback.target: a dispute names "an exact revision, not a
  # head pointer", so a dispute against revision 1 must not follow the memory to
  # revision 2.
  has_many :feedbacks, class_name: "Feedback",
                       foreign_key: %i[memory_key revision],
                       inverse_of: :memory_revision,
                       dependent: :restrict_with_exception

  def readonly?
    persisted?
  end
end
