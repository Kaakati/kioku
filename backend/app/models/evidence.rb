# frozen_string_literal: true

# A scoped handle to something observed: an origin event, a retained object, or
# both (research Appendix A, plan 5.2 "Event and evidence").
#
# The database refuses a row anchored to neither. Plan invariant 3 requires the
# bytes to be durably stored before an available reference commits, and the
# contract's kioku.evidence_required counts links before a save; a row with no
# anchor would satisfy that count while proving nothing.
class Evidence < ApplicationRecord
  self.table_name = "evidence"

  has_many :memory_links, class_name: "MemoryEvidence", foreign_key: :evidence_key,
                          primary_key: :evidence_key, inverse_of: :evidence,
                          dependent: :restrict_with_exception

  validate :anchors_to_an_event_or_an_object

  private

  def anchors_to_an_event_or_an_object
    return if origin_event_key.present? || object_key.present?

    errors.add(:base, "evidence must anchor to an origin event or a retained object")
  end
end
