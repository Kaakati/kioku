# frozen_string_literal: true

require_relative "refusals"
require_relative "schema_version"
require_relative "../contracts"

module Kioku
  module Envelope
    ErrorBody = Struct.new(:code, :message, :retryable, :retry_after_ms, :details, keyword_init: true)

    Response = Struct.new(:schema_major, :request_id, :status, :error, :data,
                          :warnings, :payload, keyword_init: true)

    # Validates what the core returned before the host renders it, so a malformed or
    # dishonest response never reaches the model as an answer
    # [contracts: envelope.response_fields; plan §6.1].
    class ResponseParser
      include Refusals

      # Read from the shared artifact, so a field the core stops rendering is a field
      # this parser stops accepting without either file being edited.
      RESPONSE_SCHEMA = Kioku::Contracts.read("envelope.response.schema.json")

      REQUIRED_FIELDS = RESPONSE_SCHEMA.fetch("required").freeze

      # "data ... Absent (null) on unauthorized_scope, deadline_expired, invalid and
      # internal_error" [contracts: envelope.response x-kioku-durability-rules].
      DATA_FORBIDDEN_STATUSES = RESPONSE_SCHEMA.fetch("x-kioku-durability-rules")
                                               .fetch("data_absent_statuses").freeze

      SPOOL_FIELDS = %w[spool_entry_id producer_key producer_epoch producer_sequence].freeze

      def call(payload:, expected_request_id: nil)
        invalid!("the response must be an object") unless payload.is_a?(Hash)
        require_fields(payload)
        major = SchemaVersion.new.call(declared: payload["schema_version"])
        status = status(payload)
        check_request_id(payload, expected_request_id)
        check_data(payload, status)

        Response.new(schema_major: major, request_id: payload["request_id"], status: status,
                     error: error_body(payload, status), data: payload["data"],
                     warnings: warnings(payload), payload: payload)
      end

      private

      def require_fields(payload)
        missing = REQUIRED_FIELDS.reject { |field| payload.key?(field) }
        return if missing.empty?

        invalid!("the response omits required fields: #{missing.sort.join(', ')}")
      end

      # D1. status is present on EVERY response, including transport-level refusals, and
      # it is the single discriminator: `invalid` carries a caller fault and
      # `internal_error` a core fault, so a 500 is no longer reported to the model as a
      # malformed request. The accepted set is the artifact's, never a count kept here.
      def status(payload)
        value = payload["status"]
        declared = Kioku::Errors.statuses
        invalid!("status must be one of the #{declared.size} declared response discriminations") unless
          declared.include?(value)
        value
      end

      # "Echoed on every response and on every receipt" [contracts: request_fields.request_id].
      def check_request_id(payload, expected_request_id)
        return if expected_request_id.nil? || payload["request_id"] == expected_request_id

        invalid!("the response echoes a different request_id than the request carried")
      end

      # "present for every status except success ... Present on partial and queued too"
      # [contracts: response_fields.error].
      def error_body(payload, status)
        error = payload["error"]
        if status == "success"
          invalid!("a success response cannot carry an error body") unless error.nil?
          return nil
        end

        invalid!("status #{status} requires an error body") unless error.is_a?(Hash)
        descriptor = descriptor_for(error["code"])
        # The registry binds each code to exactly one status. A core that paired them
        # freely could report a denial as a conflict, and a caller would retry a scope it
        # will never be granted.
        invalid!("error code #{descriptor.wire_name} does not carry status #{status}") if
          descriptor.status != status

        build_error(descriptor, error)
      end

      def descriptor_for(code)
        Kioku::Errors.fetch(code)
      rescue KeyError
        invalid!("error.code is not a frozen wire name")
      end

      def build_error(descriptor, error)
        ErrorBody.new(code: descriptor.wire_name, message: error["message"],
                      retryable: error["retryable"], retry_after_ms: error["retry_after_ms"],
                      details: error["details"] || {})
      end

      def check_data(payload, status)
        data = payload["data"]
        if DATA_FORBIDDEN_STATUSES.include?(status)
          invalid!("status #{status} must not carry data") unless data.nil?
          return
        end
        return if data.nil?

        invalid!("data must be an object") unless data.is_a?(Hash)
        check_not_saved(data, status)
        check_spool_receipt(data) if status == "queued"
      end

      # "A deadline expiry is never reported as a save" [contracts: errors
      # kioku.deadline_exceeded]; "it must never be rendered as saved" [kioku.queued].
      def check_not_saved(data, status)
        return if status == "success"
        return unless data["saved"] == true

        invalid!("status #{status} cannot report the write as saved")
      end

      def check_spool_receipt(data)
        invalid!("a queued response must carry the saved discriminator") unless data.key?("saved")
        invalid!("a queued response must report saved=false") unless data["saved"] == false

        spool = data["spool"]
        invalid!("a queued response must carry its durable spool receipt") unless spool.is_a?(Hash)
        missing = SPOOL_FIELDS.reject { |field| spool.key?(field) }
        invalid!("the spool receipt omits #{missing.sort.join(', ')}") if missing.any?
      end

      def warnings(payload)
        value = payload["warnings"]
        invalid!("warnings must be an array") unless value.is_a?(Array)
        invalid!("every warning is a coded record") unless value.all? { |entry| coded_warning?(entry) }
        value
      end

      def coded_warning?(entry)
        entry.is_a?(Hash) && entry["code"].is_a?(String)
      end
    end
  end
end
