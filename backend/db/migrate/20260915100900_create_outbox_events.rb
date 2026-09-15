# frozen_string_literal: true

# Durable outbox (Plan §5.1, §5.2, §7.1).
#
# A domain mutation and its outbox rows commit in the same transaction, so a
# crash between commit and enqueue loses nothing: the bounded dispatcher reads
# pending rows and schedules idempotent Active Jobs. Redis owns queue and retry
# scheduling; this table owns durable work intent, leases and terminal state.
class CreateOutboxEvents < ActiveRecord::Migration[8.1]
  def change
    create_outbox_events_table
    add_outbox_indexes
    add_outbox_constraints
    add_outbox_ownership_constraints
  end

  private

  def create_outbox_events_table
    create_table :outbox_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :installation, null: false, type: :uuid, foreign_key: true
      # Stable work key: the dispatcher and the job derive idempotency from it.
      t.string :outbox_event_key, null: false
      t.string :store_kind, null: false
      t.string :project_key
      t.string :event_key
      t.string :job_class, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :state, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.integer :max_attempts, null: false, default: 20
      t.string :lease_owner
      t.text :last_error
      t.column :lease_expires_at, :timestamptz
      t.column :available_at, :timestamptz, null: false, default: -> { "now()" }
      t.column :dispatched_at, :timestamptz
      t.column :completed_at, :timestamptz
      t.column :created_at, :timestamptz, null: false, default: -> { "now()" }
      t.column :updated_at, :timestamptz, null: false, default: -> { "now()" }
    end
  end

  def add_outbox_indexes
    add_index :outbox_events, :outbox_event_key, unique: true
    # The dispatcher's claim query and the lease-recovery sweep.
    add_index :outbox_events, %i[state available_at],
              where: "state IN ('pending', 'dispatched')",
              name: "index_outbox_events_on_claimable_state"
    add_index :outbox_events, :lease_expires_at, where: "state = 'dispatched'",
                                                 name: "index_outbox_events_on_expiring_leases"
    add_index :outbox_events, :event_key
    add_index :outbox_events, :project_key

    add_foreign_key :outbox_events, :events, column: :event_key, primary_key: :event_key,
                                             name: "fk_outbox_events_event_key"
    add_foreign_key :outbox_events, :projects, column: :project_key, primary_key: :project_key,
                                               name: "fk_outbox_events_project_key"
  end

  def add_outbox_constraints
    add_check_constraint :outbox_events, "btrim(outbox_event_key) <> '' AND btrim(job_class) <> ''",
                         name: "outbox_events_keys_present"
    add_check_constraint :outbox_events,
                         "state IN ('pending', 'dispatched', 'completed', 'failed')",
                         name: "outbox_events_state_valid"
    add_check_constraint :outbox_events, "attempts >= 0 AND max_attempts >= 1",
                         name: "outbox_events_attempt_counters_sane"
    add_check_constraint :outbox_events, "jsonb_typeof(payload) = 'object'",
                         name: "outbox_events_payload_is_object"

    # A lease is an owner plus an expiry, or neither; a half-set lease would make
    # recovery unable to decide whether the work is in flight.
    add_check_constraint :outbox_events,
                         "(lease_owner IS NULL AND lease_expires_at IS NULL) " \
                         "OR (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)",
                         name: "outbox_events_lease_is_whole"
    add_check_constraint :outbox_events, "(state = 'completed') = (completed_at IS NOT NULL)",
                         name: "outbox_events_completed_at_matches_state"
  end

  def add_outbox_ownership_constraints
    add_check_constraint :outbox_events, "store_kind IN ('project', 'global')",
                         name: "outbox_events_store_kind_valid"
    # Queued work keeps its original owner across a project switch (Plan §1.2).
    add_check_constraint :outbox_events,
                         "(store_kind = 'project' AND project_key IS NOT NULL) " \
                         "OR (store_kind = 'global' AND project_key IS NULL)",
                         name: "outbox_events_single_ownership_destination"
  end
end
