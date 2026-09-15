# frozen_string_literal: true

# Idempotency receipts (Plan §7.1; frozen contract kioku.tool.v1).
#
# The mutation and its receipt commit together. Repeating an idempotency key with
# the same request_digest returns the prior receipt; a different digest is a
# kioku.idempotency_conflict. The unique key below is what makes that a database
# fact rather than a race between two concurrent writers.
class CreateIdempotencyReceipts < ActiveRecord::Migration[8.1]
  def change
    create_idempotency_receipts_table
    add_receipt_indexes
    add_receipt_constraints
  end

  private

  def create_idempotency_receipts_table
    create_table :idempotency_receipts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # Covered by the actor-scoped unique index below.
      t.references :installation, null: false, type: :uuid, foreign_key: true, index: false
      t.string :receipt_key, null: false
      t.string :actor_principal_id, null: false
      t.string :idempotency_key, null: false
      t.string :request_digest, null: false
      t.string :operation, null: false
      t.string :store_kind, null: false
      t.string :project_key
      t.string :state, null: false, default: "committed"
      t.string :outbox_event_key
      # The receipt body replayed verbatim on a repeat of the same key + digest.
      t.jsonb :response_body, null: false, default: {}
      t.column :committed_at, :timestamptz
      t.column :created_at, :timestamptz, null: false, default: -> { "now()" }
    end
  end

  def add_receipt_indexes
    add_index :idempotency_receipts, :receipt_key, unique: true
    # Idempotency keys are actor-scoped; this is the collision point that turns a
    # replay into a lookup and a different payload into a conflict.
    add_index :idempotency_receipts, %i[installation_id actor_principal_id idempotency_key],
              unique: true, name: "index_idempotency_receipts_on_actor_and_key"
    add_index :idempotency_receipts, :request_digest
    add_index :idempotency_receipts, :project_key
    add_index :idempotency_receipts, :outbox_event_key

    add_foreign_key :idempotency_receipts, :projects, column: :project_key,
                                                      primary_key: :project_key,
                                                      name: "fk_idempotency_receipts_project_key"
    add_foreign_key :idempotency_receipts, :outbox_events, column: :outbox_event_key,
                                                           primary_key: :outbox_event_key,
                                                           name: "fk_idempotency_receipts_outbox_event_key"
  end

  def add_receipt_constraints
    add_check_constraint :idempotency_receipts,
                         "btrim(receipt_key) <> '' AND btrim(actor_principal_id) <> '' " \
                         "AND btrim(operation) <> ''",
                         name: "idempotency_receipts_keys_present"
    add_check_constraint :idempotency_receipts,
                         "char_length(idempotency_key) BETWEEN 1 AND 128",
                         name: "idempotency_receipts_key_length_bounded"
    add_check_constraint :idempotency_receipts,
                         "request_digest ~ '^sha256:[0-9a-f]{64}$'",
                         name: "idempotency_receipts_digest_well_formed"
    add_check_constraint :idempotency_receipts, "state IN ('committed', 'queued')",
                         name: "idempotency_receipts_state_valid"
    add_check_constraint :idempotency_receipts,
                         "(state = 'committed') = (committed_at IS NOT NULL)",
                         name: "idempotency_receipts_committed_at_matches_state"
    add_check_constraint :idempotency_receipts, "jsonb_typeof(response_body) = 'object'",
                         name: "idempotency_receipts_response_body_is_object"
    add_check_constraint :idempotency_receipts, "store_kind IN ('project', 'global')",
                         name: "idempotency_receipts_store_kind_valid"
    # The request digest includes project_key, so the same payload in a different
    # project is a different request; the receipt records which one it was.
    add_check_constraint :idempotency_receipts,
                         "(store_kind = 'project' AND project_key IS NOT NULL) " \
                         "OR (store_kind = 'global' AND project_key IS NULL)",
                         name: "idempotency_receipts_single_ownership_destination"
  end
end
