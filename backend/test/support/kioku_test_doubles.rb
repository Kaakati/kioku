# frozen_string_literal: true

module Kioku
  module Test
    # Raised by the fault-injection doubles below. It is deliberately not a
    # Context::Errors::Error: the point of the atomicity tests is that an
    # *unexpected* failure inside the canonical transaction still leaves nothing
    # behind (plan 4.1: services do not swallow unexpected exceptions or turn
    # failed saves into successful results).
    class InjectedFailure < StandardError; end

    # Stands in for Context::Storage::ObjectStore.
    #
    # It records the transaction depth observed at the moment of each call, which
    # is how the ordering obligation of plan 4.1 ("stages any required object
    # before opening the transaction") and invariant 3 ("required object bytes
    # must be durably stored before an available evidence reference commits")
    # become observable rather than assumed.
    class FakeObjectStore
      Call = Struct.new(:object_key, :transaction_depth, keyword_init: true)
      Descriptor = Struct.new(:object_key, :durable, :byte_length, :content_hash, keyword_init: true) do
        def durable?
          durable
        end
      end

      attr_reader :calls

      def initialize(durable: [])
        @durable = Array(durable).map(&:to_s)
        @calls = []
      end

      def stage(object_key:)
        key = object_key.to_s
        @calls << Call.new(object_key: key, transaction_depth: transaction_depth)
        Descriptor.new(
          object_key: key,
          durable: @durable.include?(key),
          byte_length: 11,
          content_hash: "sha256:#{Digest::SHA256.hexdigest(key)}"
        )
      end

      def durable?(object_key:)
        @durable.include?(object_key.to_s)
      end

      def staged_keys
        @calls.map(&:object_key)
      end

      def staged_transaction_depths
        @calls.map(&:transaction_depth)
      end

      private

      def transaction_depth
        ActiveRecord::Base.lease_connection.open_transactions
      end
    end

    # Stands in for the outbox writer that participates in the caller's
    # transaction (plan 5.1: "An event and its canonical outbox rows commit
    # together"). `fail_with:` injects a fault at that seam so atomicity can be
    # proved by consequence instead of by inspection.
    class FakeOutbox
      attr_reader :events

      def initialize(fail_with: nil)
        @events = []
        @fail_with = fail_with
      end

      # `work_key` mirrors the real writer's signature (plan 5.1's stable work
      # key). A double that accepts a narrower call than its subject cannot
      # detect a caller that stopped supplying one.
      def record(event_type:, payload:, work_key:, project_key: nil)
        raise @fail_with if @fail_with

        id = "outbox-event-#{@events.size + 1}"
        @events << { outbox_event_id: id, event_type: event_type, payload: payload,
                     work_key: work_key, project_key: project_key }
        id
      end

      def event_types
        @events.map { |event| event[:event_type] }
      end
    end

    # Stands in for an Active Record connection in the readiness service tests so
    # "database unreachable" and "schema absent" are separable without tearing
    # down the real database (plan 3.1 health contract).
    class FakeConnection
      def initialize(reachable: true, tables: [])
        @reachable = reachable
        @tables = Array(tables).map(&:to_s)
      end

      def select_value(_sql)
        raise ActiveRecord::ConnectionNotEstablished, "injected: database unreachable" unless @reachable

        1
      end

      def data_source_exists?(name)
        raise ActiveRecord::ConnectionNotEstablished, "injected: database unreachable" unless @reachable

        @tables.include?(name.to_s)
      end
    end

    # A readiness verdict the health controller tests can hand to the controller
    # in place of the real service, so the HTTP status is proved to follow the
    # verdict rather than being hard-coded.
    class StubReadinessResult
      attr_reader :checks

      def initialize(ready:, checks:)
        @ready = ready
        @checks = checks
      end

      def ready?
        @ready
      end
    end

    module Doubles
      def fake_object_store(durable: [])
        FakeObjectStore.new(durable: durable)
      end

      def fake_outbox(fail_with: nil)
        FakeOutbox.new(fail_with: fail_with)
      end

      def current_transaction_depth
        ActiveRecord::Base.lease_connection.open_transactions
      end
    end
  end
end
