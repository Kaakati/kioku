# frozen_string_literal: true

require "time"

module Context
  module Storage
    # Reads durable outbox rows and schedules idempotent jobs.
    #
    # PostgreSQL and Redis cannot share a transaction, so the outbox row is the
    # durable intent and this dispatcher is the bounded, restartable bridge to
    # the queue. It runs outside the writing transaction, leases rows so two
    # dispatchers do not schedule the same work, and treats an uncertain
    # enqueue acknowledgment as still-leased rather than done: duplicate
    # delivery is expected and must have no duplicate domain effect, while a
    # lost enqueue must never silently drop an accepted event.
    #
    # The enqueuer is required, not defaulted. Which job runs is the worker's
    # decision, and this object has no business naming one.
    class OutboxDispatcher
      DEFAULT_BATCH_SIZE = 100
      DEFAULT_LEASE_SECONDS = 60
      MAX_ATTEMPTS = 20

      Claim = Data.define(:event_id, :event_type, :store_kind, :project_key,
                          :aggregate_key, :aggregate_revision, :payload, :attempts)

      Report = Data.define(:claimed, :dispatched, :retained, :exhausted)

      def initialize(enqueuer:, records: Records)
        @enqueuer = enqueuer
        @records = records
      end

      def call(batch_size: DEFAULT_BATCH_SIZE, lease_seconds: DEFAULT_LEASE_SECONDS, now: Time.now.utc)
        claims = claim(batch_size, lease_seconds, now)
        dispatched = []
        retained = []
        claims.each { |claim| dispatch(claim, now) ? dispatched << claim.event_id : retained << claim.event_id }
        Report.new(claimed: claims.map(&:event_id), dispatched: dispatched, retained: retained,
                   exhausted: exhaust(retained, now))
      end

      # Called by the job once its domain effect is durable. Separate from
      # dispatched so a crash between enqueue and execution is visible.
      def complete(event_id:, now: Time.now.utc)
        records.outbox_event.where(event_id: event_id).update_all(state: "completed", completed_at: now)
      end

      private

      attr_reader :enqueuer, :records

      # Short transaction: pick claimable rows, mark them leased, commit. Rows
      # another dispatcher holds are skipped rather than waited on.
      def claim(batch_size, lease_seconds, now)
        records.base.transaction do
          rows = claimable(now).order(:available_at, :event_id).limit(batch_size).lock("FOR UPDATE SKIP LOCKED").to_a
          rows.each do |row|
            row.update!(state: "dispatching", attempts: row.attempts + 1, lease_expires_at: now + lease_seconds)
          end
          rows.map { |row| to_claim(row) }
        end
      end

      # Pending work that is due, plus leased work whose lease expired because
      # the dispatcher that held it died.
      def claimable(now)
        table = records.outbox_event.arel_table
        records.outbox_event.where(
          table[:state].eq("pending").and(table[:available_at].lteq(now)).or(
            table[:state].eq("dispatching").and(table[:lease_expires_at].lt(now))
          )
        )
      end

      def to_claim(row)
        Claim.new(event_id: row.event_id, event_type: row.event_type, store_kind: row.store_kind,
                  project_key: row.project_key, aggregate_key: row.aggregate_key,
                  aggregate_revision: row.aggregate_revision, payload: row.payload, attempts: row.attempts)
      end

      # A raised or uncertain enqueue leaves the row leased. It becomes
      # claimable again when the lease expires, which is the recovery path for
      # both a lost acknowledgment and a dead dispatcher.
      def dispatch(claim, now)
        enqueuer.call(claim)
        records.outbox_event.where(event_id: claim.event_id).update_all(state: "dispatched", dispatched_at: now)
        true
      rescue StandardError => error
        # Recorded, not swallowed: the failure class is kept on the row for an
        # operator. The message is not, because it can carry payload text.
        records.outbox_event.where(event_id: claim.event_id)
               .update_all(last_error: error.class.name, last_failed_at: now)
        false
      end

      # Retries are bounded. Work that keeps failing reaches a visible terminal
      # state for an operator instead of being reconciled forever.
      def exhaust(retained_ids, now)
        return [] if retained_ids.empty?

        exhausted = records.outbox_event.where(event_id: retained_ids).where("attempts >= ?", MAX_ATTEMPTS)
        ids = exhausted.pluck(:event_id)
        exhausted.update_all(state: "failed", failed_at: now) unless ids.empty?
        ids
      end
    end
  end
end
