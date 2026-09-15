# frozen_string_literal: true

require_relative "contracts"

module Kioku
  # The frozen kioku.tool.v1 error vocabulary, read from the shared artifact.
  #
  # `contracts/v1/errors.json` is the one table of wire names and the status and
  # retryability each resolves to. This module used to be a hand transcription of it and
  # the core kept another, which nothing could diff: the two disagreed on
  # kioku.queued.retryable (D5), and both left five codes with no status at all, so a
  # core 500 and a malformed request were indistinguishable on the single discriminator
  # and the host reported both as kioku.invalid_request (D1).
  #
  # Nothing here restates the table. Changing one code's status in the artifact changes
  # what this module answers, and contract_error_registry_test.rb is what catches a Ruby
  # constant that tried to hold a second opinion.
  module Errors
    Descriptor = Struct.new(:wire_name, :status, :retryable, keyword_init: true)

    # The eleven response discriminations: the nine of plan §6.1 plus `invalid` for a
    # caller fault and `internal_error` for a core fault. See contracts/DECISIONS.md D1.
    STATUSES = Contracts.response_statuses.freeze

    REGISTRY = Contracts.errors.each_with_object({}) do |(wire_name, entry), registry|
      registry[wire_name] = Descriptor.new(wire_name: wire_name,
                                           status: entry.fetch("status"),
                                           retryable: entry.fetch("retryable")).freeze
    end.freeze

    module_function

    def wire_names
      REGISTRY.keys
    end

    def statuses
      STATUSES.dup
    end

    # Raises KeyError for anything outside the frozen vocabulary, so an invented
    # condition cannot reach a caller under a plausible-looking name.
    def fetch(wire_name)
      REGISTRY.fetch(wire_name)
    end
  end

  # A refusal carrying its frozen wire name, the response status that name resolves to,
  # and operator-facing, content-redacted details [contracts: response_fields.error].
  class Error < StandardError
    attr_reader :code, :details

    def initialize(code, message: nil, details: {})
      @descriptor = Errors.fetch(code)
      @code = @descriptor.wire_name
      @details = details
      super(message || @descriptor.wire_name)
    end

    def status
      @descriptor.status
    end

    def retryable?
      @descriptor.retryable
    end
  end
end
