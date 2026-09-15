# frozen_string_literal: true

module Context
  # The frozen kioku.tool.v1 wire error catalogue, read from the shared artifact.
  #
  # `contracts/v1/errors.json` is the one table of wire names, the response status each
  # resolves to, whether a caller may retry, and the HTTP status the Rails surface
  # answers with. This module used to hold a hand transcription of it and the host held
  # another, which nothing could diff: the two disagreed on kioku.queued.retryable (D5),
  # and both left kioku.invalid_request, handle_unresolved, unsupported_operation,
  # unsupported_schema_version and internal_error with NO status at all (D1) — so a core
  # 500 and a malformed request were indistinguishable on the single discriminator, and a
  # model asking for a handle that does not exist was told its request was malformed.
  #
  # The classes stay, because the code raises them by name and rescues them by ancestry.
  # What they no longer carry is an opinion: `wire code:` looks the rest up.
  module Errors
    REGISTRY = {}

    class Error < StandardError
      class << self
        attr_reader :wire_code, :wire_status, :http_status

        # The status stays a Symbol because the core speaks its own enums in
        # symbols and renders them on the wire once, in Serialization::Wire. The
        # artifact decides WHICH status; the spelling is the core's own.
        def wire(code:)
          entry = Contracts.errors.fetch(code)
          @wire_code = code
          @wire_status = entry.fetch("status").to_sym
          @http_status = entry.fetch("http_status")
          @retryable = entry.fetch("retryable")
          Errors.register(self)
        end

        def retryable?
          @retryable
        end
      end

      attr_reader :details, :retry_after_ms, :http_status

      # `http_status` overrides the class default for the one case the artifact records
      # as an override: an unrecognised bridge credential is denied with the frozen
      # kioku.scope_denied code but answered 401, because the credential rather than the
      # requested scope is what failed [contracts: errors.json kioku.scope_denied].
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
      wire code: "kioku.partial_result"
    end

    # "Replay after reconnect returns the same idempotency receipt", so re-issuing with
    # the same key and digest is how a caller learns the commit outcome — which is what
    # retryable means. The artifact settles it; this class no longer votes (D5).
    class Queued < Error
      wire code: "kioku.queued"
    end

    # --- conflicts ----------------------------------------------------------

    class RevisionConflict < Error
      wire code: "kioku.revision_conflict"
    end

    class IdempotencyConflict < Error
      wire code: "kioku.idempotency_conflict"
    end

    class AuthorityViolation < Error
      wire code: "kioku.authority_violation"
    end

    class EvidenceRequired < Error
      wire code: "kioku.evidence_required"
    end

    class ContinuationExpired < Error
      wire code: "kioku.continuation_expired"
    end

    class PreconditionFailed < Error
      wire code: "kioku.precondition_failed"
    end

    # --- scope --------------------------------------------------------------

    class ScopeDenied < Error
      wire code: "kioku.scope_denied"
    end

    class ProjectBindingUnresolved < Error
      wire code: "kioku.project_binding_unresolved"
    end

    # --- availability and budget --------------------------------------------

    class SourceUnavailable < Error
      wire code: "kioku.source_unavailable"
    end

    class EvidenceUnavailable < Error
      wire code: "kioku.evidence_unavailable"
    end

    class QuotaExhausted < Error
      wire code: "kioku.quota_exhausted"
    end

    class DeadlineExceeded < Error
      wire code: "kioku.deadline_exceeded"
    end

    # --- request validation -------------------------------------------------

    # Not-found and wrong-scope are deliberately merged so the two are indistinguishable
    # to the caller (plan 5.3). The status is unauthorized_scope because the caller's
    # branch is the same in both cases — this is not obtainable — and both merged
    # branches already answer 404, so nothing is disclosed on that channel either.
    class HandleUnresolved < Error
      wire code: "kioku.handle_unresolved"
    end

    class InvalidRequest < Error
      wire code: "kioku.invalid_request"
    end

    class UnsupportedSchemaVersion < Error
      wire code: "kioku.unsupported_schema_version"
    end

    class UnsupportedOperation < Error
      wire code: "kioku.unsupported_operation"
    end

    # The contract requires this message to be content- and credential-redacted. The
    # raised text is kept on the exception for the server log and is never rendered on
    # the wire. `internal_error` is a status of its own because mapping a core fault onto
    # any caller-fault value reports a 500 as a client error.
    class InternalError < Error
      REDACTED_MESSAGE = "an unexpected internal failure occurred"

      wire code: "kioku.internal_error"

      def wire_message
        REDACTED_MESSAGE
      end
    end
  end
end
