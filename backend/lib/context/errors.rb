# frozen_string_literal: true

module Context
  # The frozen Phase 0 error catalogue, one class per wire name.
  #
  # The wire name, response status, retryability and meaning of every entry are
  # data in contracts/schemas/errors.v1.json; this file is the Ruby mirror and
  # is checked against that file by .verify_catalogue!.
  #
  # STATUS is nil for failures the contract surfaces at the transport level
  # with no `status` field — Phase 0 deliberately left the tenth status value
  # ("invalid") as an additive v1.1 decision rather than overloading one of the
  # nine.
  #
  # Messages are operator-facing and must stay content- and credential-redacted:
  # never pass a memory title, body, query text or secret into `message`. Put
  # identifiers in `details`.
  module Errors
    # Base class. Services raise these; the HTTP/MCP boundary maps them to a
    # response through Context::Serialization::Result.from_error.
    class Error < StandardError
      attr_reader :details, :retry_after_ms

      def initialize(message = nil, details: {}, retry_after_ms: nil)
        super(message || self.class.default_message)
        @details = details.freeze
        @retry_after_ms = retry_after_ms
      end

      def self.default_message = name.split("::").last
      def wire_name = self.class::WIRE_NAME
      def status = self.class::STATUS
      def retryable? = self.class::RETRYABLE

      def to_h
        {
          code: wire_name,
          message: message,
          retryable: retryable?,
          retry_after_ms: retry_after_ms,
          details: details
        }
      end
    end

    class RevisionConflict < Error
      WIRE_NAME = "kioku.revision_conflict"
      STATUS = "conflict"
      RETRYABLE = false
      def self.default_message = "Expected revision is stale; nothing was written"
    end

    class IdempotencyConflict < Error
      WIRE_NAME = "kioku.idempotency_conflict"
      STATUS = "conflict"
      RETRYABLE = false
      def self.default_message = "Idempotency key reused with a different request digest"
    end

    class PreconditionFailed < Error
      WIRE_NAME = "kioku.precondition_failed"
      STATUS = "conflict"
      RETRYABLE = false
      def self.default_message = "Observed heads or receipt state no longer apply"
    end

    class AuthorityViolation < Error
      WIRE_NAME = "kioku.authority_violation"
      STATUS = "conflict"
      RETRYABLE = false
      def self.default_message = "The actor lacks the authority for this transition"
    end

    class EvidenceRequired < Error
      WIRE_NAME = "kioku.evidence_required"
      STATUS = "conflict"
      RETRYABLE = false
      def self.default_message = "No eligible evidence link was supplied"
    end

    class ContinuationExpired < Error
      WIRE_NAME = "kioku.continuation_expired"
      STATUS = "conflict"
      RETRYABLE = false
      def self.default_message = "Continuation cursor expired or its binding no longer matches"
    end

    class ScopeDenied < Error
      WIRE_NAME = "kioku.scope_denied"
      STATUS = "unauthorized_scope"
      RETRYABLE = false
      def self.default_message = "Requested scope is not granted to this principal"
    end

    class ProjectBindingUnresolved < Error
      WIRE_NAME = "kioku.project_binding_unresolved"
      STATUS = "unauthorized_scope"
      RETRYABLE = false
      def self.default_message = "Project binding is missing or ambiguous"
    end

    class SourceUnavailable < Error
      WIRE_NAME = "kioku.source_unavailable"
      STATUS = "unavailable_source"
      RETRYABLE = true
      def self.default_message = "Requested source validation could not be completed"
    end

    class EvidenceUnavailable < Error
      WIRE_NAME = "kioku.evidence_unavailable"
      STATUS = "evidence_unavailable"
      RETRYABLE = false
      def self.default_message = "Referenced evidence is deleted, expired, purged or redacted"
    end

    class QuotaExhausted < Error
      WIRE_NAME = "kioku.quota_exhausted"
      STATUS = "quota_exhausted"
      RETRYABLE = true
      def self.default_message = "Installation or actor budget exceeded"
    end

    class DeadlineExceeded < Error
      WIRE_NAME = "kioku.deadline_exceeded"
      STATUS = "deadline_expired"
      RETRYABLE = true
      def self.default_message = "Bounded deadline elapsed before a result was produced"
    end

    class InvalidRequest < Error
      WIRE_NAME = "kioku.invalid_request"
      STATUS = nil
      RETRYABLE = false
      def self.default_message = "Request failed contract validation"
    end

    # not-found and wrong-scope are deliberately indistinguishable here so that
    # content addressing cannot expose cross-scope existence (Plan §5.3). The
    # internal audit log distinguishes them.
    class HandleUnresolved < Error
      WIRE_NAME = "kioku.handle_unresolved"
      STATUS = nil
      RETRYABLE = false
      def self.default_message = "Handle did not resolve"
    end

    class UnsupportedOperation < Error
      WIRE_NAME = "kioku.unsupported_operation"
      STATUS = nil
      RETRYABLE = false
      def self.default_message = "Operation or enum value is not supported by this contract version"
    end

    class UnsupportedSchemaVersion < Error
      WIRE_NAME = "kioku.unsupported_schema_version"
      STATUS = nil
      RETRYABLE = false
      def self.default_message = "Unsupported schema_version major"
    end

    # No partial write is implied. Services never swallow unexpected exceptions
    # and never turn a failed save into a successful result (Plan §4.1).
    class InternalError < Error
      WIRE_NAME = "kioku.internal_error"
      STATUS = nil
      RETRYABLE = false
      def self.default_message = "Unexpected internal failure"
    end

    CLASSES = [
      RevisionConflict, IdempotencyConflict, PreconditionFailed, AuthorityViolation,
      EvidenceRequired, ContinuationExpired, ScopeDenied, ProjectBindingUnresolved,
      SourceUnavailable, EvidenceUnavailable, QuotaExhausted, DeadlineExceeded,
      InvalidRequest, HandleUnresolved, UnsupportedOperation, UnsupportedSchemaVersion,
      InternalError
    ].freeze

    BY_WIRE_NAME = CLASSES.to_h { |klass| [klass::WIRE_NAME, klass] }.freeze

    module_function

    def fetch(wire_name)
      BY_WIRE_NAME.fetch(wire_name) do
        raise ArgumentError, "unknown Kioku error wire name: #{wire_name.inspect}"
      end
    end

    # Raises unless every raisable entry of the frozen catalogue has a class
    # here with the same status and retryability. Called from tests and from
    # the contract self-check.
    def verify_catalogue!
      catalogue = Contracts::SchemaRegistry.dig!("errors", "x-kioku", "catalogue")
      catalogue.each do |wire_name, entry|
        next unless entry["raised_by_core"]

        klass = fetch(wire_name)
        mismatch = { status: [klass::STATUS, entry["status"]], retryable: [klass::RETRYABLE, entry["retryable"]] }
                   .reject { |_key, (ruby, json)| ruby == json }
        raise ArgumentError, "#{wire_name} drifted from errors.v1.json: #{mismatch}" if mismatch.any?
      end
      true
    end
  end
end
