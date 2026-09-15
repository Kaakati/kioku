# frozen_string_literal: true

require "time"

require_relative "../errors"

module Kioku
  module Agent
    # The response envelopes the AGENT itself produces, when the core did not
    # produce one [contracts: envelope.response.schema.json].
    #
    # There are exactly two: the durable-enqueue answer, and a refusal the host
    # decided by itself. Everything else the caller sees is the core's own
    # envelope relayed verbatim — the agent holds no storage authority and does
    # not restate the core's answer in its own words.
    #
    # `generation_vector` is null on both. The contract says the key is always
    # present and the value is null when the request was refused before scope
    # resolution, and neither of these ever reached the core's scope resolution.
    # Rendering zeroed counters here would be a generation the host never
    # observed, which is the false-confirmation invariant 6 forbids.
    module Responses
      SCHEMA_VERSION = "kioku.tool.v1"
      COMPLETENESS_LABEL = "known_within_indexed_coverage"

      QUEUED_MESSAGE = "the capture is durably enqueued on the host spool and has not " \
                       "reached canonical commit"

      module_function

      # "queued means durable host enqueue only; saved means canonical commit. A
      # timeout or missing acknowledgment is never reported as a save"
      # [contracts: errors kioku.queued; plan invariant 2]. The spool receipt is
      # what makes the claim checkable: it names the entry the caller can find on
      # disk.
      def queued(envelope:, receipt:, started_at: Time.now.utc)
        common(envelope, "queued", Kioku::Errors.fetch("kioku.queued"), QUEUED_MESSAGE, {},
               started_at)
          .merge("data" => { "saved" => false, "spool" => spool_receipt(receipt) })
      end

      # A refusal the host decided: the spool refused the capture, or the call
      # never named something the agent could act on. It carries no data, so an
      # empty answer can never be mistaken for a completed one.
      def refusal(envelope:, error:, started_at: Time.now.utc)
        common(envelope, error.status, Kioku::Errors.fetch(error.code), error.message,
               error.details, started_at)
          .merge("data" => nil)
      end

      def spool_receipt(receipt)
        {
          "spool_entry_id" => receipt.spool_entry_id,
          "producer_key" => receipt.producer_key,
          "producer_epoch" => receipt.producer_epoch,
          "producer_sequence" => receipt.producer_sequence
        }
      end

      def common(envelope, status, descriptor, message, details, started_at)
        now = Time.now.utc
        {
          "schema_version" => SCHEMA_VERSION,
          "request_id" => envelope&.request_id,
          "status" => status,
          "error" => error_body(descriptor, message, details),
          "generation_vector" => nil,
          "coverage" => coverage,
          "continuation" => nil,
          "limits" => limits(envelope, started_at, now),
          "warnings" => [],
          "server_time" => now.iso8601(3)
        }
      end

      def error_body(descriptor, message, details)
        { "code" => descriptor.wire_name, "message" => message,
          "retryable" => descriptor.retryable, "retry_after_ms" => nil,
          "details" => details }
      end

      # The host evaluated no candidate set, so coverage is unknown rather than
      # complete. `complete_for_declared_set` here would claim the write was
      # assessed against everything it declared, which is exactly what did not
      # happen.
      def coverage
        { "state" => "unknown", "declared_input_set" => {},
          "counts" => { "considered" => 0, "returned" => 0, "truncated_at" => nil },
          "gaps" => [], "completeness_label" => COMPLETENESS_LABEL }
      end

      def limits(envelope, started_at, now)
        { "deadline_at" => envelope && (started_at + (envelope.deadline_ms / 1000.0)).iso8601(3),
          "elapsed_ms" => ((now - started_at) * 1000).round,
          "candidate_limit" => nil, "returned" => nil, "truncated" => false }
      end
    end
  end
end
