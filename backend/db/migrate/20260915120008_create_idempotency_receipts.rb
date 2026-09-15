# frozen_string_literal: true

# Idempotency receipts (plan 5.2 "idempotency receipts", plan 7.1 step 5: "A
# short transaction commits event/revision/head/search projection, outbox and
# idempotency receipt").
#
# The columns are the frozen contract's receipt verbatim —
# `{receipt_id, idempotency_key, request_digest, committed_at, replayed}` — minus
# `replayed`, which is a property of the current call rather than of the stored
# row: a receipt that is found is by definition a replay.
#
# Plan 7.1: "Repeating the same idempotency key and payload returns the prior
# receipt; a different payload conflicts." The unique index on idempotency_key is
# what makes that a decision instead of a race: two concurrent writers with the
# same key cannot both commit a first receipt.
class CreateIdempotencyReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :idempotency_receipts, id: :text, primary_key: :receipt_id do |t|
      t.text :idempotency_key, null: false
      t.text :request_digest, null: false
      # The committed outcome the key resolves to. Nullable because a receipt is
      # written only for a commit, and a mutation that commits nothing addressable
      # (a future non-memory use case) still owns its key.
      t.text :memory_key
      t.bigint :revision
      t.timestamptz :committed_at, null: false
    end

    add_index :idempotency_receipts, :idempotency_key, unique: true
    add_index :idempotency_receipts, %i[memory_key revision],
              name: "idempotency_receipts_outcome"
    add_foreign_key :idempotency_receipts, :memory_revisions,
                    column: %i[memory_key revision], primary_key: %i[memory_key revision]
    # A receipt names either a whole outcome or none of it; half of a composite
    # key is a reference that resolves to nothing.
    add_check_constraint :idempotency_receipts,
                         "(memory_key IS NULL) = (revision IS NULL)",
                         name: "idempotency_receipts_outcome_complete"
  end
end
