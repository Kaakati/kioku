# frozen_string_literal: true

require "time"

module Context
  module Queries
    # Observes the generation counters that accompany every response.
    #
    # These are observations taken in one short read, not locks. A global
    # update advances the global generation; an override or profile edit
    # advances that project's policy generation; privacy deletion advances a
    # deletion epoch (Plan §5.2, §5.3). The host source epoch is whatever the
    # host last reported — a file on disk can change a microsecond later, and no
    # database read makes that atomic.
    class Generations
      COUNTER_KINDS = %w[canonical policy global index source_epoch deletion_epoch].freeze

      def initialize(records: Storage::Records)
        @records = records
      end

      # host_link_state is supplied by the caller because only the component
      # holding the control connection knows it. It defaults to disconnected:
      # an unobserved link is never reported as connected, and a disconnected
      # link can never yield applicability=source_checked.
      def call(installation_id:, project_key: nil, host_link_state: "disconnected", now: Time.now.utc)
        counters = counters_for(installation_id)
        counters = counters.merge(counters_for(project_key)) if project_key
        Serialization::GenerationVector.parse(counters, host_link_state: host_link_state, observed_at: now)
      end

      private

      def counters_for(subject_key)
        @records.generation_counter
                .where(subject_key: subject_key, counter_kind: COUNTER_KINDS)
                .to_h { |row| [row.counter_kind, row.value] }
      end
    end
  end
end
