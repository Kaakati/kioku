# frozen_string_literal: true

require "kioku/request_digest"

module Kioku
  module TestSupport
    # What a caller that computed its own digest would have sent.
    #
    # `Envelopes#mutation_envelope` fills request_digest with an arbitrary shape-valid
    # string, which was harmless while nothing recomputed it. E1 gives
    # `Kioku::RequestDigest` its first caller at the tool boundary: the digest is
    # recomputed over the received body and a mismatch is refused with
    # kioku.invalid_request.
    #
    # Without signing, every mutation case in this suite would be refused for its
    # digest whatever else it was measuring. The cases that expect
    # kioku.invalid_request would all still pass — and would be measuring the digest
    # rather than the smuggled claim_support, the blank summary or the invented enum
    # value they name. That is the defect Q2 and Q3 were, arriving in bulk.
    #
    # A read envelope carries no digest and is handed back untouched, so the reads in
    # these files still exercise the path they always did.
    module ContractSigning
      def signed(arguments)
        envelope = arguments["envelope"]
        return arguments unless envelope.is_a?(Hash) && envelope.key?("request_digest")

        digest = Kioku::RequestDigest.compute(arguments)
        arguments.merge("envelope" => envelope.merge("request_digest" => digest))
      end
    end
  end
end
