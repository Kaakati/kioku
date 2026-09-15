# frozen_string_literal: true

require "test_helper"

# Plan 4.1 (reference service), plan 7.1 (capture and durable save), invariant 2
# ("saved means canonical commit; a timeout or missing acknowledgment is never
# reported as a save") and invariant 3 ("required object bytes must be durably
# stored before an available evidence reference commits").
#
# Test classes stay top level on purpose: `module Context` here would reopen the
# Zeitwerk-managed application namespace and put test constants inside it.
class RememberDurabilityTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport

  setup do
    arrange_project_with_durable_evidence
  end

  test "should report saved with a canonical receipt when the transaction commits" do
    outbox = fake_outbox
    service = remember_service(outbox: outbox)

    result = service.call(**remember_arguments)

    assert_predicate result, :saved?
    assert_equal :success, result.status
    assert_equal 1, result.revision
    assert_equal 1, result.head_revision
    assert_equal 1, revisions_for(result.memory_key).count
    assert_equal 1, receipt_count("idem-1")
    assert_equal [result.outbox_event_id], outbox.events.map { |event| event[:outbox_event_id] }
  end

  test "should persist nothing and report no save when the canonical transaction rolls back" do
    service = remember_service(outbox: fake_outbox(fail_with: Kioku::Test::InjectedFailure))

    assert_raises(Kioku::Test::InjectedFailure) do
      service.call(**remember_arguments)
    end

    assert_equal 0, memory_revision_count
    assert_equal 0, memory_count
    assert_equal 0, receipt_count("idem-1")
    assert_equal 0, search_document_count
  end

  test "should leave the head at its prior revision when the outbox write fails on an append" do
    create_memory(memory_key: "memory-1", revisions: 1)
    service = remember_service(outbox: fake_outbox(fail_with: Kioku::Test::InjectedFailure))

    assert_raises(Kioku::Test::InjectedFailure) do
      service.call(**remember_arguments(memory_key: "memory-1",
                                        envelope: mutation_envelope(expected_revision: 1)))
    end

    assert_equal 1, memory_record("memory-1").current_revision
    assert_equal 1, revisions_for("memory-1").count
  end

  test "should stage required evidence objects before opening the canonical transaction" do
    object_store = fake_object_store(durable: [Kioku::Test::Factories::DURABLE_OBJECT_KEY])
    depth_before_call = current_transaction_depth

    remember_service(object_store: object_store).call(**remember_arguments)

    assert_equal [Kioku::Test::Factories::DURABLE_OBJECT_KEY], object_store.staged_keys
    assert_equal [depth_before_call], object_store.staged_transaction_depths
  end

  test "should raise rather than report a save when the object store is unreachable" do
    unreachable = Object.new
    def unreachable.stage(object_key:)
      raise Kioku::Test::InjectedFailure, "object store unreachable for #{object_key}"
    end

    assert_raises(Kioku::Test::InjectedFailure) do
      remember_service(object_store: unreachable).call(**remember_arguments)
    end

    assert_equal 0, memory_revision_count
    assert_equal 0, receipt_count("idem-1")
  end
end
