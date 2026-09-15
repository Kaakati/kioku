# frozen_string_literal: true

# Idempotency keys are ACTOR-SCOPED (frozen contract, envelope.idempotency_key:
# "string (<=128 chars, actor-scoped)"). Migration 20260915120008 made the key
# unique across the whole table, which states a different contract: one caller's
# key is every caller's key.
#
# Two consequences follow, and a suite that exercises one actor can see neither:
#
#   * a second actor reusing the key with a colliding digest is handed the first
#     actor's receipt, and is told a memory it never wrote was saved;
#   * a second actor reusing it with a different digest is handed a conflict whose
#     details carry the first actor's receipt_id and request_digest — a
#     cross-actor disclosure in a system that deliberately merges not-found with
#     wrong-scope (kioku.handle_unresolved) so that neither can be probed.
#
# The scope is (installation_key, actor_principal_id, idempotency_key). The
# principal alone is not a scope: two installations mint principals
# independently, so one spelling can name two different writers. Both columns are
# NOT NULL because NULLs are distinct in a unique index — a nullable actor column
# would restore the unscoped behaviour for every receipt that omitted it.
class ScopeIdempotencyReceiptsToActor < ActiveRecord::Migration[8.1]
  def up
    add_column :idempotency_receipts, :installation_key, :text, null: false
    add_column :idempotency_receipts, :actor_principal_id, :text, null: false

    remove_index :idempotency_receipts, column: :idempotency_key
    # Still unique, still the arbiter of two concurrent writers (plan 7.1 step 5)
    # — now over the scope the contract declares. Its leading column is also the
    # supporting index for the installation_key foreign key.
    add_index :idempotency_receipts,
              %i[installation_key actor_principal_id idempotency_key],
              unique: true, name: "idempotency_receipts_actor_key_unique"
    add_foreign_key :idempotency_receipts, :installations,
                    column: :installation_key, primary_key: :installation_key
  end

  def down
    remove_foreign_key :idempotency_receipts, column: :installation_key
    remove_index :idempotency_receipts, name: "idempotency_receipts_actor_key_unique"
    add_index :idempotency_receipts, :idempotency_key, unique: true
    remove_column :idempotency_receipts, :actor_principal_id
    remove_column :idempotency_receipts, :installation_key
  end
end
