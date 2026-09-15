# frozen_string_literal: true

module Kioku
  # Turns raw tool arguments into a validated, enveloped request for the agent.
  #
  # This is the contract layer the MCP adapter and contextctl share. It does
  # what a JSON Schema cannot express faithfully: it answers a removed retrieval
  # mode with kioku.unsupported_operation rather than a generic schema error, it
  # expands the deprecated mode=solutions alias, and it enforces that a
  # context_task call carries only the fields its own op defines.
  class ToolRequest
    attr_reader :tool, :op, :envelope, :arguments

    def self.build(tool:, arguments:)
      new(tool: tool, arguments: arguments).tap(&:prepare)
    end

    # The checks that must answer kioku.unsupported_operation rather than a
    # schema violation, run before schema validation so a permanently removed
    # mode or an unknown op gets its contract error and not a generic one.
    def self.precheck!(tool:, arguments:)
      new(tool: tool, arguments: arguments).precheck!
    end

    def initialize(tool:, arguments:)
      raise Kioku.unsupported_operation("unknown tool", { "requested" => tool }) unless Kioku::TOOLS.include?(tool)

      @tool = tool
      @raw = Kioku::CanonicalJson.canonicalize(arguments || {})
      raise Kioku.invalid_request("tool arguments must be an object") unless @raw.is_a?(Hash)

      @op = @raw["op"] if tool == "context_task"
    end

    def precheck!
      check_task_op!
      check_removed_modes!
      self
    end

    def prepare
      precheck!
      reject_foreign_task_fields!
      normalized = normalize
      mutation = Kioku.mutation?(@tool, normalized)
      @envelope, @arguments = Kioku::Envelope.prepare(
        normalized, mutation: mutation, default_deadline_ms: Kioku::Deadlines.default_for(@tool, @op)
      )
      clamp_deadline!
      self
    end

    def mutation?
      Kioku.mutation?(@tool, @raw)
    end

    def payload
      { "tool" => @tool, "envelope" => @envelope, "arguments" => @arguments }
    end

    def socket_deadline_ms
      @envelope["deadline_ms"] + Kioku::Deadlines::SOCKET_GRACE_MS
    end

    private

    # semantic and hybrid are permanently unsupported: embeddings, vector search
    # and hybrid search are out of scope, not deferred.
    def check_removed_modes!
      return unless @tool == "context_search"
      return unless Kioku::Schemas::Retrieval::REMOVED_MODES.include?(@raw["mode"])

      raise Kioku.unsupported_operation(
        "embeddings, vector search and hybrid search are out of scope",
        { "requested_mode" => @raw["mode"], "supported_modes" => %w[exact lexical related] }
      )
    end

    # The deprecated mode=solutions alias expands to
    # {mode: lexical, profile: solutions}, so "how it was found" and "what was
    # asked for" stay separable.
    def normalize
      args = @raw.dup
      return args unless @tool == "context_search" && args["mode"] == "solutions"

      args.merge("mode" => "lexical", "profile" => args["profile"] || "solutions")
    end

    def check_task_op!
      return unless @tool == "context_task"
      return if Kioku::Schemas::Task::OPS.include?(@op)

      raise Kioku.unsupported_operation("unknown context_task op", { "requested" => @op })
    end

    def reject_foreign_task_fields!
      return unless @tool == "context_task"

      allowed = Kioku::Schemas::Task::FIELDS_BY_OP.fetch(@op)
      foreign = @raw.keys - allowed
      return if foreign.empty?

      raise Kioku.invalid_request(
        "fields do not belong to context_task op=#{@op}",
        { "rejected_fields" => foreign, "permitted_fields" => allowed }
      )
    end

    def clamp_deadline!
      @envelope["deadline_ms"] = Kioku::Deadlines.clamp(@tool, @op, @envelope["deadline_ms"])
    end
  end
end
