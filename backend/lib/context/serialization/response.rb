# frozen_string_literal: true

module Context
  module Serialization
    # The common response envelope (plan 6.1, frozen contract `response_fields`).
    #
    # `coverage` and `generation_vector` are always rendered. `continuation` is
    # reads-only, so the key is always present and is null on a mutation rather
    # than omitted — a caller branches on one field either way.
    #
    # `status` is omitted when the caller has none to report. The contract says
    # of the request-validation codes: "for v1 this returns HTTP/MCP-level error
    # with code kioku.invalid_request and no status field".
    module Response
      SCHEMA_VERSION = Contracts::Envelope::SCHEMA_VERSION

      def self.call(request_id:, generation_vector:, coverage:, limits:, server_time:,
                    status: nil, data: nil, error: nil, continuation: nil,
                    receipt: nil, warnings: [])
        payload = { "schema_version" => SCHEMA_VERSION, "request_id" => request_id }
        payload["status"] = status.to_s unless status.nil?
        payload.merge(
          "error" => Wire.render(error),
          "data" => render_data(data),
          "generation_vector" => Wire.render(generation_vector),
          "coverage" => Wire.render(coverage),
          "continuation" => Wire.render(continuation),
          "receipt" => Wire.render(receipt),
          "limits" => Wire.render(limits),
          "warnings" => Wire.render(warnings),
          "server_time" => server_time
        )
      end

      # Returned records go through Item so the six evidence dimensions are
      # rendered the same way on every surface.
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
