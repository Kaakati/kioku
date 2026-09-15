# frozen_string_literal: true

module Context
  module Storage
    # The one place the library names Active Record models.
    #
    # This is not a repository layer: callers get the real model class and use
    # the full Active Record API on it. It exists so the seam between this
    # library and app/models is a single file rather than a constant reference
    # in every storage and query object, which matters because the two are
    # written and reviewed separately.
    #
    # Constants resolve lazily, at call time, so this file loads before the
    # models do.
    module Records
      module_function

      # The connection owner. Services open their transaction on this class and
      # storage objects assert they are inside it.
      def base = ::ActiveRecord::Base

      def project = ::Project
      def project_root = ::ProjectRoot
      def scope_grant = ::ScopeGrant
      def memory = ::Memory
      def memory_revision = ::MemoryRevision
      def memory_evidence = ::MemoryEvidence
      def memory_search_document = ::MemorySearchDocument
      def project_preference_override = ::ProjectPreferenceOverride
      def event = ::Event
      def evidence = ::Evidence
      def source_object = ::SourceObject
      def idempotency_receipt = ::IdempotencyReceipt
      def outbox_event = ::OutboxEvent
      def generation_counter = ::GenerationCounter

      # True only inside an open transaction on the connection the caller will
      # write through. Storage operations participate in the service's
      # transaction; they never open or commit one of their own (Plan §4.1).
      def transaction_open?
        base.current_transaction.open?
      end

      def assert_in_transaction!(operation)
        return true if transaction_open?

        raise Errors::InternalError.new(details: { reason: "storage_called_outside_transaction", operation: operation })
      end
    end
  end
end
