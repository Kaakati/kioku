# frozen_string_literal: true

module Kioku
  # The frozen kioku.tool.v1 error vocabulary.
  #
  # Every wire name, and the response status it resolves to, is copied from the Phase 0
  # contract [contracts: errors[]; envelope.response_fields.status]. Codes the contract
  # leaves without a `status=` sentence carry none here either: kioku.invalid_request is
  # returned at the transport level with no status field in v1, and the contract assigns
  # no status to handle_unresolved, unsupported_operation, unsupported_schema_version or
  # internal_error [contracts: open_decisions "the tenth transport-level status"].
  module Errors
    STATUSES = %w[
      success partial queued conflict unauthorized_scope
      unavailable_source evidence_unavailable quota_exhausted deadline_expired
    ].freeze

    Descriptor = Struct.new(:wire_name, :status, :retryable, keyword_init: true)

    # wire name, response status (nil when the contract assigns none), retryable
    DEFINITIONS = [
      ["ok",                              "success",            false],
      ["kioku.partial_result",            "partial",            false],
      ["kioku.queued",                    "queued",             true],
      ["kioku.revision_conflict",         "conflict",           false],
      ["kioku.scope_denied",              "unauthorized_scope", false],
      ["kioku.source_unavailable",        "unavailable_source", true],
      ["kioku.evidence_unavailable",      "evidence_unavailable", false],
      ["kioku.quota_exhausted",           "quota_exhausted",    true],
      ["kioku.deadline_exceeded",         "deadline_expired",   true],
      ["kioku.invalid_request",           nil,                  false],
      ["kioku.idempotency_conflict",      "conflict",           false],
      ["kioku.handle_unresolved",         nil,                  false],
      ["kioku.project_binding_unresolved", "unauthorized_scope", false],
      ["kioku.authority_violation",       "conflict",           false],
      ["kioku.evidence_required",         "conflict",           false],
      ["kioku.continuation_expired",      "conflict",           false],
      ["kioku.precondition_failed",       "conflict",           false],
      ["kioku.unsupported_operation",     nil,                  false],
      ["kioku.unsupported_schema_version", nil,                 false],
      ["kioku.internal_error",            nil,                  false]
    ].freeze

    REGISTRY = DEFINITIONS.each_with_object({}) do |(wire_name, status, retryable), registry|
      registry[wire_name] = Descriptor.new(wire_name: wire_name, status: status, retryable: retryable).freeze
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
