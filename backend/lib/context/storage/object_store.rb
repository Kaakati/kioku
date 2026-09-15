# frozen_string_literal: true

module Context
  module Storage
    # The retained-object half of invariant 3: "required object bytes are durably
    # stored before an available evidence reference commits".
    #
    # Staging is a READ of recorded object state, not an upload. The host agent
    # uploads bytes and the core records them (plan 7.1 step 3); what this answers
    # is whether the bytes a write wants to point at are retained now. A reference
    # to bytes that were never stored, or that a purge has removed, is reported as
    # not durable so the use case can reject it rather than commit an available
    # reference to nothing.
    #
    # It deliberately reports rather than raises: a well-formed reference the core
    # cannot resolve belongs in data.evidence_rejected, and only an empty eligible
    # set fails the write with kioku.evidence_required (contracts: tools
    # context_remember).
    class ObjectStore
      RETAINED = "available"

      Staged = Struct.new(:object_key, :durable, :byte_length, :content_hash,
                          keyword_init: true) do
        def durable?
          durable
        end
      end

      def stage(object_key:)
        key = object_key.to_s
        record = SourceObject.find_by(object_key: key)
        return Staged.new(object_key: key, durable: false) if record.nil?

        Staged.new(object_key: record.object_key, durable: record.availability == RETAINED,
                   byte_length: record.byte_length, content_hash: record.content_hash)
      end
    end
  end
end
