# frozen_string_literal: true

module Context
  module Serialization
    # The common response envelope (plan 6.1, frozen contract `response_fields`).
    #
    # `coverage` and `generation_vector` are always rendered. `continuation` is
    # reads-only, so the key is always present and is null on a mutation rather than
    # omitted — a caller branches on one field either way.
    #
    # D1. `status` is present on EVERY response, including transport-level refusals, and
    # it is a REQUIRED keyword argument so a caller cannot reach the wire without one.
    # This module used to omit the key when the error resolved to no status, which is
    # five of the twenty wire names; a caller then had to branch on `status || error.code`
    # — the inconsistent branching the contract warns about — and a core 500 became
    # indistinguishable from a malformed request, so the host reported both as
    # kioku.invalid_request and a model was told to fix a request that was fine.
    module Response
      SCHEMA_VERSION = Contracts::Envelope::SCHEMA_VERSION

      def self.call(request_id:, status:, generation_vector:, coverage:, limits:, server_time:,
                    data: nil, error: nil, continuation: nil, receipt: nil, warnings: [])
        {
          "schema_version" => SCHEMA_VERSION,
          "request_id" => request_id,
          "status" => status.to_s,
          "error" => Wire.render(error),
          "data" => render_data(data),
          "generation_vector" => Wire.render(generation_vector),
          "coverage" => Wire.render(coverage),
          "continuation" => Wire.render(continuation),
          "receipt" => Wire.render(receipt),
          "limits" => Wire.render(limits),
          "warnings" => Wire.render(warnings),
          "server_time" => server_time
        }
      end

      # Returned records go through Item so the six evidence dimensions are rendered the
      # same way on every surface.
      def self.render_data(payload)
        return nil if payload.nil?

        rendered = Wire.render(payload)
        items = payload.to_h[:items] || payload.to_h["items"]
        return rendered if items.nil?

        rendered.merge("items" => items.map { |item| Item.call(item: item) })
      end
      private_class_method :render_data
    end
  end
end
