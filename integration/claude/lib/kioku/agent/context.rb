# frozen_string_literal: true

require_relative "../approved_roots"
require_relative "../source_reader"
require_relative "bridge"
require_relative "control_channel"
require_relative "project_binding"
require_relative "replay"

module Kioku
  module Agent
    # The agent's collaborators, wired once. Host filesystem authority
    # (approved roots, path resolution, source reads and hashing) lives behind
    # this object and nowhere else in the package.
    class Context
      attr_reader :config, :logger, :roots, :source, :binding, :spool, :bridge, :control, :replay

      def initialize(config:, logger:)
        @config = config
        @logger = logger
        @roots = Kioku::ApprovedRoots.new(config.approved_roots)
        @source = Kioku::SourceReader.new(roots: @roots)
        @binding = ProjectBinding.new(config: config, roots: @roots)
        @spool = Kioku.spool_for(config)
        @bridge = build_bridge
        @control = build_control
        @replay = Replay.new(spool: @spool, bridge: @bridge, logger: logger)
      end

      def start
        @spool.start_epoch!
        @control.start
        self
      end

      def stop
        @control.stop
      end

      private

      def build_bridge
        Bridge.new(
          api_url: @config.api_url, token: @config.bridge_token,
          logger: @logger, installation_id: @config.installation_id
        )
      end

      # The core reaches the host only through this channel, and only for the
      # named source operations.
      def build_control
        ControlChannel.new(
          api_url: @config.api_url, token: @config.bridge_token,
          installation_id: @config.installation_id, logger: @logger,
          handler: method(:handle_control_request)
        )
      end

      def handle_control_request(op, payload)
        case op
        when "source.validate" then validate_paths(payload)
        when "source.manifest" then @source.manifest(path: payload["path"])
        when "source.read" then read_source(payload)
        else raise Kioku.unsupported_operation("unknown control op", { "requested" => op })
        end
      end

      def validate_paths(payload)
        results = Array(payload["paths"]).first(200).map do |item|
          @source.validate(path: item["path"], expected_hash: item["expected_hash"])
        end
        { "results" => results }
      end

      def read_source(payload)
        @source.read(
          path: payload["path"],
          max_bytes: payload.fetch("max_bytes", Kioku::SourceReader::MAX_READ_BYTES),
          byte_start: payload.fetch("byte_start", 0)
        )
      end
    end
  end
end
