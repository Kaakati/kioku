# frozen_string_literal: true

require "time"

module Context
  module Serialization
    # The observed generation vector carried on every response.
    #
    # source_epoch is an observation, not a lock: one PostgreSQL database does
    # not make a host file read atomic with database state (Plan §6.1). The
    # host link state is reported as observed — a disconnected control
    # connection yields historical or unknown applicability, never
    # source_checked.
    class GenerationVector < Data.define(
      :canonical_generation, :policy_generation, :global_generation,
      :index_generation, :source_epoch, :deletion_epoch, :host_link_state, :observed_at
    )
      def initialize(canonical_generation: 0, policy_generation: 0, global_generation: 0,
                     index_generation: 0, source_epoch: 0, deletion_epoch: 0,
                     host_link_state: "disconnected", observed_at: Time.now.utc)
        super
      end

      def self.parse(counters, host_link_state:, observed_at: Time.now.utc)
        Contracts::Validator.enum!(host_link_state, field: "host_link_state", allowed: Contracts::Vocabulary.host_link_states)
        new(
          canonical_generation: counters.fetch("canonical", 0),
          policy_generation: counters.fetch("policy", 0),
          global_generation: counters.fetch("global", 0),
          index_generation: counters.fetch("index", 0),
          source_epoch: counters.fetch("source_epoch", 0),
          deletion_epoch: counters.fetch("deletion_epoch", 0),
          host_link_state: host_link_state,
          observed_at: observed_at.utc
        )
      end

      def host_connected? = host_link_state == "connected"

      def to_wire
        to_h.transform_keys(&:to_s).merge("observed_at" => observed_at.utc.iso8601(3))
      end

      # Bound into continuation cursors: changed index data may require a reset
      # rather than a promise of permanent score ordering.
      def digest = Contracts::Canonical.digest(to_wire)
    end
  end
end
