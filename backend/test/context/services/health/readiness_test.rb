# frozen_string_literal: true

require "test_helper"

# Compose/plan 3.1 health contract: GET /up is readiness, not liveness. It
# returns 200 only after real database connectivity AND schema presence both
# hold, and 503 otherwise. This pins the verdict; the controller test pins the
# status code that must follow it.
class HealthReadinessTest < ActiveSupport::TestCase
  CANONICAL_TABLE = "memories"

  test "should report not ready when the database connection cannot be established" do
    result = readiness(Kioku::Test::FakeConnection.new(reachable: false))

    refute_predicate result, :ready?
    assert_equal :failed, result.checks[:database_connectivity]
  end

  test "should not claim schema presence when the database connection cannot be established" do
    result = readiness(Kioku::Test::FakeConnection.new(reachable: false))

    refute_equal :present, result.checks[:schema_presence]
  end

  test "should report not ready when the database answers but the canonical schema is absent" do
    result = readiness(Kioku::Test::FakeConnection.new(reachable: true, tables: []))

    refute_predicate result, :ready?
    assert_equal :ok, result.checks[:database_connectivity]
    assert_equal :absent, result.checks[:schema_presence]
  end

  test "should report not ready when only migration bookkeeping tables exist" do
    result = readiness(Kioku::Test::FakeConnection.new(reachable: true,
                                                      tables: %w[schema_migrations ar_internal_metadata]))

    refute_predicate result, :ready?
    assert_equal :absent, result.checks[:schema_presence]
  end

  test "should report ready when connectivity and canonical schema presence both hold" do
    result = readiness(Kioku::Test::FakeConnection.new(reachable: true, tables: [CANONICAL_TABLE]))

    assert_predicate result, :ready?
    assert_equal :ok, result.checks[:database_connectivity]
    assert_equal :present, result.checks[:schema_presence]
  end

  private

  def readiness(connection)
    Context::Services::Health::Readiness.new(connection: connection).call
  end
end
