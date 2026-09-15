# frozen_string_literal: true

require_relative "../envelope"
require_relative "../errors"
require_relative "responses"

module Kioku
  module Agent
    # One tool call, as the host agent performs it [plan §7.1 steps 2 and 6].
    #
    #   2. The capture is persisted to the durable spool BEFORE delivery is
    #      attempted, so a crash between here and the core cannot lose a capture
    #      the caller was about to be told about.
    #   6. The entry is retired only once a canonical receipt acknowledges it.
    #
    # Everything between those two steps is the core's to decide. The agent holds
    # no storage authority: it relays the core's envelope verbatim and produces
    # an answer of its own only when there is no core answer to relay, in which
    # case that answer is `queued` and never `saved`.
    class ToolCall
      TOOL_PATH_PREFIX = "/api/v1/"
      SUPPORTED_OP = "tool_call"

      # The one condition under which the call did not reach the core at all.
      UNDELIVERED = "kioku.source_unavailable"

      def initialize(spool:, core:, logger:)
        @spool = spool
        @core = core
        @logger = logger
        @lock = Mutex.new
      end

      # Total by construction: a control connection always gets one response
      # envelope back, because the caller's deadline is the only other thing that
      # can end the call and a silent close would be indistinguishable from a
      # save that is still in flight.
      def call(frame:)
        started_at = Time.now.utc
        envelope = nil
        @lock.synchronize do
          envelope = decode(frame)
          perform(frame, envelope, started_at)
        end
      rescue Kioku::Error => error
        refuse(frame, envelope, error, started_at)
      rescue StandardError => error
        @logger.error("the host agent could not complete the call: #{error.class}")
        refuse(frame, envelope, internal_error, started_at)
      end

      private

      attr_reader :spool, :core, :logger

      def decode(frame)
        invalid!("the control frame must name a tool call") unless tool_call?(frame)

        Kioku::Envelope.parse_request(frame.dig("request", "envelope"),
                                      mutation: mutation?(frame))
      end

      def tool_call?(frame)
        frame.is_a?(Hash) && frame["op"] == SUPPORTED_OP &&
          frame["tool"].is_a?(String) && frame["request"].is_a?(Hash)
      end

      # A mutation is a call that carries the mutation envelope. That is what
      # decides whether the capture is spooled, rather than a list of tool names
      # the agent would have to keep in step with the contract.
      def mutation?(frame)
        frame.dig("request", "envelope").is_a?(Hash) &&
          frame.dig("request", "envelope").key?("idempotency_key")
      end

      def perform(frame, envelope, started_at)
        receipt = enqueue(frame, envelope)
        deliver(frame, envelope, receipt, started_at)
      end

      # Plan §7.1 step 2. A replayed key hands back the prior receipt instead of
      # enqueuing the capture twice.
      def enqueue(frame, envelope)
        return nil if envelope.idempotency_key.nil?

        spool.enqueue(envelope: frame.fetch("request"),
                      idempotency_key: envelope.idempotency_key,
                      request_digest: envelope.request_digest)
      end

      def deliver(frame, envelope, receipt, started_at)
        answer = core.post(path: "#{TOOL_PATH_PREFIX}#{frame.fetch('tool')}",
                           payload: frame.fetch("request"), deadline_ms: envelope.deadline_ms)
        retire(receipt, answer)
        answer
      rescue Kioku::Error => error
        raise error unless queueable?(receipt, error)

        Responses.queued(envelope: envelope, receipt: receipt, started_at: started_at)
      end

      # `queued` is a durability claim about a capture that is on the spool right
      # now and has not been committed. A capture whose canonical receipt already
      # arrived is neither, so reporting it as queued would deny a commit that
      # happened; the unreachable core is reported as unreachable instead.
      def queueable?(receipt, error)
        !receipt.nil? && !receipt.saved? && error.code == UNDELIVERED
      end

      # Plan §7.1 step 6: "The agent acknowledges/retires spool entries only
      # after the canonical receipt." A committed answer names a receipt with the
      # time it was committed; anything else leaves the capture pending.
      def retire(receipt, answer)
        return if receipt.nil? || receipt.saved?

        canonical = canonical_receipt(answer)
        return if canonical.nil?

        spool.acknowledge(spool_entry_id: receipt.spool_entry_id, canonical_receipt: canonical)
      end

      def canonical_receipt(answer)
        canonical = answer["receipt"]
        return nil unless canonical.is_a?(Hash) && canonical["committed_at"]

        canonical
      end

      def refuse(frame, envelope, error, started_at)
        logger.warn("#{frame.is_a?(Hash) ? frame['tool'] : 'control frame'} refused: #{error.code}")

        Responses.refusal(envelope: envelope, error: error, started_at: started_at)
      end

      def internal_error
        Kioku::Error.new("kioku.internal_error",
                         message: "the host agent could not complete the call")
      end

      def invalid!(detail)
        raise Kioku::Error.new("kioku.invalid_request", message: detail)
      end
    end
  end
end
