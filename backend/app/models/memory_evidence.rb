# frozen_string_literal: true

# The link between one memory revision and one piece of evidence, carrying the
# relation it was recorded with (research Appendix A).
#
# `relation` is not decoration: the contract's partial-result rule says "Material
# contrary evidence is never the thing dropped to fit", which is only enforceable
# while a contradicting link stays distinguishable from a supporting one.
class MemoryEvidence < ApplicationRecord
  self.table_name = "memory_evidence"

  RELATIONS = %w[supports contradicts context].freeze

  belongs_to :memory_revision, foreign_key: %i[memory_key revision],
                               inverse_of: :evidence_links

  belongs_to :evidence, foreign_key: :evidence_key, primary_key: :evidence_key,
                        inverse_of: :memory_links

  validates :relation, inclusion: { in: RELATIONS }
end
