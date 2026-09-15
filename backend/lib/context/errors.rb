# frozen_string_literal: true

module Context
  # The frozen Phase 0 wire error catalogue (contracts.json `errors`).
  #
  # Each class binds three things the boundary needs and nothing else: the wire
  # `code` a caller branches on, the nine-way response `status` of plan 6.1, and
  # the HTTP status the code maps to. The status/HTTP table is the interpretation
  # recorded with these tests; the wire codes are frozen and are not.
  #
  # `status` is deliberately absent on the request-validation codes. The frozen
  # contract says of kioku.invalid_request: "for v1 this returns HTTP/MCP-level
  # error with code kioku.invalid_request and no status field", and names no
  # status for kioku.handle_unresolved or kioku.internal_error either. A response
  # for those omits the field rather than inventing a tenth enum value.
  module Errors
    REGISTRY = {}

    class Error < StandardError
      class << self
        attr_reader :wire_code, :wire_status, :http_status

        def wire(code:, http:, status: nil, retryable: false)
          @wire_code = code
          @http_status = http
          @wire_status = status
          @retryable = retryable
          Errors.register(self)
        end

        def retryable?
          @retryable
        end
      end

      attr_reader :details, :retry_after_ms, :http_status

      # `http_status` overrides the class default for the one case the contract
      # does not cover: an unrecognised bridge credential is denied with the
      # frozen kioku.scope_denied code but answered 401, because the credential
      # rather than the requested scope is what failed.
      def initialize(message = nil, details: {}, retry_after_ms: nil, http_status: nil)
        @details = details || {}
        @retry_after_ms = retry_after_ms
        @http_status = http_status || self.class.http_status
        super(message || self.class.wire_code)
      end

      def wire_code
        self.class.wire_code
      end

      def wire_status
        self.class.wire_status
      end

      def retryable?
        self.class.retryable?
      end

      # Operator-facing text. Overridden where the contract requires redaction.
      def wire_message
        message
      end

      def to_wire
        {
          code: wire_code,
          message: wire_message,
          retryable: retryable?,
          retry_after_ms: retry_after_ms,
          details: details
        }
      end
    end

    def self.register(klass)
      REGISTRY[klass.wire_code] = klass
    end

    def self.fetch(code)
      REGISTRY.fetch(code.to_s) do
        raise KeyError, "#{code.inspect} is not a frozen kioku wire error code"
      end
    end

    # --- not failures -------------------------------------------------------

    class PartialResult < Error
      wire code: "kioku.partial_result", http: :ok, status: :partial
    end

    class Queued < Error
      wire code: "kioku.queued", http: :accepted, status: :queued
    end

    # --- conflicts ----------------------------------------------------------

    class RevisionConflict < Error
      wire code: "kioku.revision_conflict", http: :conflict, status: :conflict
    end

    class IdempotencyConflict < Error
      wire code: "kioku.idempotency_conflict", http: :conflict, status: :conflict
    end

    class AuthorityViolation < Error
      wire code: "kioku.authority_violation", http: :conflict, status: :conflict
    end

    class EvidenceRequired < Error
      wire code: "kioku.evidence_required", http: :conflict, status: :conflict
    end

    class ContinuationExpired < Error
      wire code: "kioku.continuation_expired", http: :conflict, status: :conflict
    end

    class PreconditionFailed < Error
      wire code: "kioku.precondition_failed", http: :precondition_failed, status: :conflict
    end

    # --- scope --------------------------------------------------------------

    class ScopeDenied < Error
      wire code: "kioku.scope_denied", http: :forbidden, status: :unauthorized_scope
    end

    class ProjectBindingUnresolved < Error
      wire code: "kioku.project_binding_unresolved", http: :forbidden, status: :unauthorized_scope
    end

    # --- availability and budget --------------------------------------------

    class SourceUnavailable < Error
      wire code: "kioku.source_unavailable", http: :service_unavailable,
           status: :unavailable_source, retryable: true
    end

    class EvidenceUnavailable < Error
      wire code: "kioku.evidence_unavailable", http: :gone, status: :evidence_unavailable
    end

    class QuotaExhausted < Error
      wire code: "kioku.quota_exhausted", http: :too_many_requests,
           status: :quota_exhausted, retryable: true
    end

    # The contract states the caller retries a deadline expiry with the same
    # idempotency key and request digest, so this one is retryable by design.
    class DeadlineExceeded < Error
      wire code: "kioku.deadline_exceeded", http: :gateway_timeout,
           status: :deadline_expired, retryable: true
    end

    # --- request validation -------------------------------------------------

    # Not-found and wrong-scope are deliberately merged so the two are
    # indistinguishable to the caller (plan 5.3).
    class HandleUnresolved < Error
      wire code: "kioku.handle_unresolved", http: :not_found
    end

    class InvalidRequest < Error
      wire code: "kioku.invalid_request", http: :bad_request
    end

    class UnsupportedSchemaVersion < Error
      wire code: "kioku.unsupported_schema_version", http: :bad_request
    end

    class UnsupportedOperation < Error
      wire code: "kioku.unsupported_operation", http: :bad_request
    end

    # The contract requires this message to be content- and credential-redacted.
    # The raised text is kept on the exception for the server log and is never
    # rendered on the wire.
    class InternalError < Error
      REDACTED_MESSAGE = "an unexpected internal failure occurred"

      wire code: "kioku.internal_error", http: :internal_server_error

      def wire_message
        REDACTED_MESSAGE
      end
    end
  end
end
