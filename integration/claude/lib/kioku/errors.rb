# frozen_string_literal: true

module Kioku
  # The nine response discriminations of Plan 6.1.
  STATUSES = %w[
    success partial queued conflict unauthorized_scope
    unavailable_source evidence_unavailable quota_exhausted deadline_expired
  ].freeze

  # Statuses a caller must treat as a failure. `partial` and `queued` are not
  # failures: the contract is explicit that both carry an error object while
  # still being an honest, usable answer.
  FAILED_STATUSES = %w[
    conflict unauthorized_scope unavailable_source
    evidence_unavailable quota_exhausted deadline_expired
  ].freeze

  # The twenty frozen wire error names, in contract order.
  WIRE_CODES = %w[
    ok
    kioku.partial_result
    kioku.queued
    kioku.revision_conflict
    kioku.scope_denied
    kioku.source_unavailable
    kioku.evidence_unavailable
    kioku.quota_exhausted
    kioku.deadline_exceeded
    kioku.invalid_request
    kioku.idempotency_conflict
    kioku.handle_unresolved
    kioku.project_binding_unresolved
    kioku.authority_violation
    kioku.evidence_required
    kioku.continuation_expired
    kioku.precondition_failed
    kioku.unsupported_operation
    kioku.unsupported_schema_version
    kioku.internal_error
  ].freeze

  # Status implied by a code when the responder did not supply one. Codes absent
  # from this table are transport-level and carry no status field at all, which
  # is the frozen behaviour for kioku.invalid_request,
  # kioku.unsupported_schema_version, kioku.handle_unresolved,
  # kioku.unsupported_operation and kioku.internal_error.
  CODE_STATUS = {
    "ok" => "success",
    "kioku.partial_result" => "partial",
    "kioku.queued" => "queued",
    "kioku.revision_conflict" => "conflict",
    "kioku.idempotency_conflict" => "conflict",
    "kioku.authority_violation" => "conflict",
    "kioku.evidence_required" => "conflict",
    "kioku.continuation_expired" => "conflict",
    "kioku.precondition_failed" => "conflict",
    "kioku.scope_denied" => "unauthorized_scope",
    "kioku.project_binding_unresolved" => "unauthorized_scope",
    "kioku.source_unavailable" => "unavailable_source",
    "kioku.evidence_unavailable" => "evidence_unavailable",
    "kioku.quota_exhausted" => "quota_exhausted",
    "kioku.deadline_exceeded" => "deadline_expired"
  }.freeze

  RETRYABLE_CODES = %w[
    kioku.queued
    kioku.deadline_exceeded
    kioku.quota_exhausted
    kioku.source_unavailable
    kioku.internal_error
  ].freeze

  # One frozen wire error. `message` is operator-facing and must stay free of
  # remembered content and credentials.
  class Error < StandardError
    attr_reader :code, :details, :retry_after_ms

    def initialize(code, message, details: {}, retry_after_ms: nil)
      raise ArgumentError, "unknown wire error name: #{code.inspect}" unless WIRE_CODES.include?(code)

      super(message)
      @code = code
      @details = details
      @retry_after_ms = retry_after_ms
    end

    # nil for the transport-level codes, which deliberately carry no status.
    def status
      CODE_STATUS[@code]
    end

    def retryable?
      RETRYABLE_CODES.include?(@code)
    end

    def to_error_object
      {
        "code" => @code,
        "message" => message,
        "retryable" => retryable?,
        "retry_after_ms" => @retry_after_ms,
        "details" => @details
      }
    end
  end

  # A host-local transport (the agent's Unix socket, or the authenticated
  # loopback bridge to the core) is not reachable. Hook callers degrade on this
  # and return without enhancement; tool callers either spool the write and
  # answer `queued`, or report the read failure honestly. Nothing is ever
  # reported as saved because of it.
  class TransportUnavailable < Error
    attr_reader :component

    def initialize(component, reason)
      @component = component
      super(
        "kioku.internal_error",
        "#{component} is not reachable: #{reason}",
        details: { "reason" => "transport_unavailable", "component" => component }
      )
    end
  end

  def self.invalid_request(message, details = {})
    Error.new("kioku.invalid_request", message, details: details)
  end

  def self.unsupported_operation(message, details = {})
    Error.new("kioku.unsupported_operation", message, details: details)
  end
end
