# frozen_string_literal: true

require "test_helper"

# Frozen contract, envelope.idempotency_key: "string (<=128 chars, ACTOR-SCOPED)".
#
# Migration 20260915120008 puts a unique index on `idempotency_key` alone and the
# table carries no actor or installation column at all, so one caller's key is
# every caller's key. Two consequences follow, and the current suite can see
# neither because it exercises one actor and the literal key "idem-1":
#
#   * a second actor reusing the key with a colliding digest is handed the first
#     actor's receipt, and is told a memory it never wrote was saved;
#   * a second actor reusing the key with a different digest is handed a conflict
#     whose details carry the first actor's receipt_id and request_digest — a
#     cross-actor disclosure in a system whose rule is not to reveal whether a
#     target exists in another scope (plan 5.3; kioku.handle_unresolved
#     deliberately merges not-found with wrong-scope for exactly this reason).
#
# The scope is (installation_key, actor_principal_id, idempotency_key). The
# principal alone is not a scope: two installations mint principals
# independently, so the same principal string can name two different writers.
#
# These inserts name the columns this contract requires. A further column must be
# nullable or carry a default, per the rule in test/support/schema_contract.rb.
class IdempotencyReceiptActorScopeTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @installation = seed_installation
    @other_installation = seed_installation
  end

  test "should accept one idempotency key held by two different actor principals" do
    # Arrange
    seed_receipt(idempotency_key: "idem-shared", actor_principal_id: "actor-a")

    # Act — the second actor has never used this key, whatever the first did.
    seed_receipt(idempotency_key: "idem-shared", actor_principal_id: "actor-b")

    # Assert
    assert_equal %w[actor-a actor-b], principals_holding("idem-shared"),
                 "An actor-scoped key must leave each actor its own key space."
  end

  test "should refuse a second receipt for an idempotency key the same actor already holds" do
    # Arrange — this is the constraint that makes replay a decision rather than a
    # race: two concurrent writers with the same actor and key cannot both commit
    # a first receipt (plan 7.1 step 5).
    seed_receipt(idempotency_key: "idem-own", actor_principal_id: "actor-a")

    # Act / Assert
    assert_database_rejects(because: [PG::UniqueViolation],
                            describing: "a repeated key for the same actor") do
      seed_receipt(idempotency_key: "idem-own", actor_principal_id: "actor-a")
    end
    assert_equal 1, receipt_rows("idem-own")
  end

  test "should accept one idempotency key held by the same principal under two installations" do
    # Arrange
    seed_receipt(idempotency_key: "idem-cross", actor_principal_id: "kioku.host_bridge")

    # Act — a different installation is a different writer even under an
    # identically spelled principal.
    seed_receipt(idempotency_key: "idem-cross", actor_principal_id: "kioku.host_bridge",
                 installation_key: @other_installation)

    # Assert
    assert_equal 2, receipt_rows("idem-cross")
  end

  test "should refuse a receipt that names no writing actor" do
    # Arrange / Act / Assert — NULLs are distinct in a unique index, so a
    # nullable actor column would hand every unattributed receipt back to the
    # unscoped behaviour this migration is fixing.
    assert_database_rejects(because: [PG::NotNullViolation],
                            describing: "a receipt with no actor principal") do
      seed_receipt(idempotency_key: "idem-anonymous", actor_principal_id: nil)
    end
  end

  test "should refuse a receipt that names no installation" do
    # Arrange / Act / Assert
    assert_database_rejects(because: [PG::NotNullViolation],
                            describing: "a receipt with no installation") do
      seed_receipt(idempotency_key: "idem-homeless", actor_principal_id: "actor-a",
                   installation_key: nil)
    end
  end

  private

  # memory_key and revision are left NULL on purpose: the outcome-completeness
  # CHECK accepts a receipt that names neither, and the scope under test is
  # independent of what the key resolved to.
  def seed_receipt(idempotency_key:, actor_principal_id:, installation_key: @installation,
                   request_digest: new_content_hash, receipt_id: new_key("receipt"))
    insert_row("idempotency_receipts",
               receipt_id: receipt_id,
               idempotency_key: idempotency_key,
               actor_principal_id: actor_principal_id,
               installation_key: installation_key,
               request_digest: request_digest,
               committed_at: Time.current)
    receipt_id
  end

  def principals_holding(idempotency_key)
    rows = select_rows(ActiveRecord::Base.sanitize_sql_array([<<~SQL, idempotency_key]))
      SELECT actor_principal_id
      FROM idempotency_receipts
      WHERE idempotency_key = ?
      ORDER BY actor_principal_id
    SQL
    rows.map { |row| row["actor_principal_id"] }
  end

  def receipt_rows(idempotency_key)
    row_count("idempotency_receipts",
              ActiveRecord::Base.sanitize_sql_array(["idempotency_key = ?", idempotency_key]))
  end
end
