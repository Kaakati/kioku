# frozen_string_literal: true

require "time"

module Context
  module Serialization
    # The response envelope, shared by the HTTP/UI surface and the MCP adapter
    # so neither invents its own shape (Plan §6.1).
    #
    # status is the single discriminator and error.code refines it. `partial`
    # and `queued` are not failures and still carry an error object, so a caller
    # can branch on one field. The core never produces `queued`: durable host
    # enqueue happens on the host spool, and only the host adapter can honestly
    # report it.
    class Result < Data.define(
      :status, :request_id, :data, :error, :generation_vector,
      :coverage, :continuation, :receipt, :limits, :warnings, :server_time
    )
      def self.success(request_id:, deadline:, generation_vector:, coverage:, data: nil, **options)
        build(status: "success", request_id: request_id, deadline: deadline,
              generation_vector: generation_vector, coverage: coverage, data: data, **options)
      end

      # Data is present and truncated; coverage carries the gaps. Nothing is
      # silently shortened, and material contrary evidence is never the thing
      # dropped to fit.
      PARTIAL_ERROR = {
        code: "kioku.partial_result", message: "declared portion could not be served",
        retryable: false, retry_after_ms: nil, details: {}
      }.freeze

      def self.partial(request_id:, deadline:, generation_vector:, coverage:, data:, **options)
        build(status: "partial", request_id: request_id, deadline: deadline,
              generation_vector: generation_vector, coverage: coverage, data: data,
              error: PARTIAL_ERROR, **options)
      end

      # Maps a raised Context::Errors::Error. An error with no status is a
      # transport-level failure: the boundary renders error alone.
      def self.from_error(error:, request_id:, deadline:, generation_vector: nil, coverage: nil, **options)
        build(status: error.status, request_id: request_id, deadline: deadline,
              generation_vector: generation_vector, coverage: coverage,
              data: nil, error: error.to_h, **options)
      end

      def self.build(status:, request_id:, deadline:, generation_vector:, coverage:, data: nil, error: nil,
                     receipt: nil, continuation: nil, warnings: [], token_budget: nil,
                     candidate_limit: nil, returned: 0, truncated: false, now: Time.now.utc)
        new(
          status: status, request_id: request_id, data: data, error: error,
          generation_vector: generation_vector, coverage: coverage, continuation: continuation,
          receipt: receipt, warnings: warnings.freeze, server_time: now.utc,
          limits: limits_for(deadline, data, token_budget, candidate_limit, returned, truncated, now)
        )
      end

      def self.limits_for(deadline, data, token_budget, candidate_limit, returned, truncated, now)
        {
          "deadline_at" => deadline.deadline_at_iso,
          "elapsed_ms" => deadline.elapsed_ms(now),
          "candidate_limit" => candidate_limit,
          "returned" => returned,
          "truncated" => truncated,
          "token_accounting" => TokenAccountant.account(data || {}, budget: token_budget)
        }
      end

      private_class_method :build, :limits_for

      def success? = status == "success"

      def to_wire
        {
          "schema_version" => Context::CONTRACT_ID,
          "request_id" => request_id,
          "status" => status,
          "error" => error && error.transform_keys(&:to_s),
          "data" => data,
          "generation_vector" => generation_vector&.to_wire,
          "coverage" => coverage&.to_wire,
          "continuation" => continuation&.to_wire,
          "receipt" => receipt,
          "limits" => limits,
          "warnings" => warnings,
          "server_time" => server_time.utc.iso8601(3)
        }
      end
    end
  end
end
