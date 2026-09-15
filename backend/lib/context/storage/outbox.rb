# frozen_string_literal: true

module Context
  module Storage
    # The durable outbox write behind plan 5.1's "An event and its canonical
    # outbox rows commit together".
    #
    # Plan 5.1 names the shortcut this refuses: "Merely using `after_commit` or
    # Active Job's deferred enqueue does not make commit and scheduling atomic."
    # So `record` participates in the caller's transaction and never opens one of
    # its own — not even a savepoint, which would let the announcement survive the
    # rollback of the change it announces and schedule work for a revision nobody
    # can read.
    class Outbox
      # Undispatched, and therefore claimable by the reconciliation loop.
      DISPATCH_STATE = "pending"

      # `work_key` is supplied by the caller because only the caller knows what
      # change this announces; it is the identity of the work, so a redispatch of
      # already-accepted work collides here rather than running twice.
      #
      # Returns the identifier context_remember reports as data.outbox_event_id,
      # so a caller told its work was queued is told the name of a row that
      # exists.
      def record(event_type:, payload:, work_key:, project_key: nil)
        OutboxEvent.create!(
          outbox_event_id: "outbox-event-#{SecureRandom.uuid_v7}",
          work_key: work_key,
          event_type: event_type,
          payload: payload,
          project_key: project_key,
          dispatch_state: DISPATCH_STATE,
          recorded_at: Time.current
        ).outbox_event_id
      end
    end
  end
end
