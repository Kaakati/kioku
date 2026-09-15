# frozen_string_literal: true

module Context
  module Serialization
    # One returned record.
    #
    # Invariant 1 and Research 5: authority, lifecycle, availability,
    # applicability, claim support and coverage are six separate dimensions and
    # are never collapsed into one verified boolean or a confidence float. The
    # field list below is a whitelist for exactly that reason — a caller cannot
    # smuggle a `confidence` or `verified` field onto an item by putting one in
    # the hash it hands over.
    #
    # A BM25 score is a relevance score and is rendered under `relevance`; it is
    # never claim support (frozen contract, `labels.relevance`).
    module Item
      FIELDS = %i[
        handle subject_kind store_kind owner title revision head_revision
        authority lifecycle availability applicability claim_support coverage
        relevance dispute override_status
      ].freeze

      def self.call(item:)
        source = item.to_h
        FIELDS.to_h { |field| [field.to_s, Wire.render(source[field])] }
      end
    end
  end
end
