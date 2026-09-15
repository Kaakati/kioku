# frozen_string_literal: true

require "test_helper"

# Plan 7.1 step 5 and the stack acceptance criterion of plan 9: "Concurrent
# PostgreSQL writes cannot duplicate revisions/receipts."
#
# The CREATE path in `Remember` has no lock and no guard except the receipt's
# unique index. Two callers with the same idempotency key and no memory_key both
# pass the replay lookup, both create a memory, and one of them raises
# ActiveRecord::RecordNotUnique out of the receipt insert. That is not a
# Context::Errors::Error, so it escapes `Remember#call`'s rescue and the API
# boundary's rescue_from alike: nothing is written, and the caller is handed a
# bare 500 instead of the kioku.idempotency_conflict or the replayed receipt the
# contract promises.
#
# The window is opened deliberately here rather than waited for. `Remember`
# stages evidence after its replay lookup and before it opens the canonical
# transaction, so a barrier in the object store — an injected collaborator, the
# same seam the durability suite already uses for fault injection — releases both
# callers into exactly the interval the receipt index has to arbitrate.
#
# The transactional-test wrapper is off because a race needs two connections, and
# a connection outside the test's transaction cannot see uncommitted rows.
class RememberConcurrentIdempotencyTest < ActiveSupport::TestCase
  include Kioku::Test::RememberSupport
  include Kioku::Test::PersistenceActors

  self.use_transactional_tests = false

  RACE_KEY = "idem-concurrent"

  # Releases every caller only once all of them have arrived, so neither can
  # finish its transaction before the other has passed the replay lookup.
  class Barrier
    class NotReached < StandardError; end

    def initialize(size, timeout: 10)
      @size = size
      @timeout = timeout
      @arrived = 0
      @mutex = Mutex.new
      @condition = ConditionVariable.new
    end

    def wait
      @mutex.synchronize do
        @arrived += 1
        next @condition.broadcast if @arrived >= @size

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        until @arrived >= @size
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise NotReached, "only #{@arrived} of #{@size} callers reached the barrier" if remaining <= 0

          @condition.wait(@mutex, remaining)
        end
      end
    end
  end

  class BarrierObjectStore < Kioku::Test::FakeObjectStore
    def initialize(barrier:, durable: [])
      super(durable: durable)
      @barrier = barrier
    end

    def stage(object_key:)
      descriptor = super
      @barrier.wait
      descriptor
    end
  end

  setup do
    assert_canonical_schema_present
    truncate_canonical_tables!
    arrange_project_with_durable_evidence
    @barrier = Barrier.new(2)
  end

  teardown do
    truncate_canonical_tables!
  end

  test "should commit one memory and report it to both callers when concurrent writes share a key and digest" do
    # Arrange / Act
    results = race do
      racing_service.call(**remember_arguments(actor: racing_actor, envelope: race_envelope))
    end

    # Assert — one commit, and the loser is answered from the receipt rather than
    # with the raw uniqueness error the database raised at it.
    assert_equal 2, results.count(&:saved?)
    assert_equal 1, results.map(&:memory_key).uniq.size
    assert_equal 1, results.count { |result| result.receipt.replayed? }
    assert_equal 1, memory_count
    assert_equal 1, revisions_for(results.first.memory_key).count
    assert_equal 1, receipt_count(RACE_KEY)
  end

  test "should refuse the losing caller with an idempotency conflict when concurrent writes differ in digest" do
    # Arrange / Act — same key, two different payloads, no prior receipt.
    results = race do |index|
      racing_service.call(**remember_arguments(
        actor: racing_actor,
        envelope: race_envelope(request_digest: request_digest_for("payload-#{index}")),
        body: "Concurrent conclusion number #{index}."
      ))
    end

    # Assert
    refused = results.reject(&:saved?)
    assert_equal 1, results.count(&:saved?)
    assert_equal ["kioku.idempotency_conflict"], refused.map(&:error_code)
    assert_equal [:conflict], refused.map(&:status)
    assert_equal 1, memory_count,
                 "The losing caller's own memory head must roll back with its receipt; a refusal " \
                 "that leaves a revision behind is a write reported as a failure."
    assert_equal 1, receipt_count(RACE_KEY)
  end

  private

  # Thread#value re-raises, so an exception that escapes the service fails the
  # test as itself instead of being flattened into a missing result.
  def race
    threads = Array.new(2) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { yield(index) }
      end
    end
    threads.map(&:value)
  end

  def racing_service
    remember_service(object_store: BarrierObjectStore.new(
      barrier: @barrier, durable: [Kioku::Test::Factories::DURABLE_OBJECT_KEY]
    ))
  end

  def racing_actor
    writing_actor(principal_id: "kioku.host_bridge")
  end

  def race_envelope(request_digest: nil)
    mutation_envelope(idempotency_key: RACE_KEY, request_digest: request_digest)
  end
end
