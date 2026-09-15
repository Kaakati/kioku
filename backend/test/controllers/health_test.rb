# frozen_string_literal: true

require "test_helper"

# Compose/plan 3.1 health contract, restated in config/routes.rb: GET /up is
# readiness, not liveness. It returns 200 only after database connectivity AND
# schema presence both hold, and 503 otherwise. An endpoint that renders an
# unconditional 200 fails this suite.
class HealthEndpointTest < ActionDispatch::IntegrationTest
  test "should answer 503 when the readiness check reports the database unreachable" do
    with_readiness(ready: false, checks: { database_connectivity: :failed, schema_presence: :unknown }) do
      get "/up"
    end

    assert_response :service_unavailable
    assert_equal "failed", parsed_health.dig("checks", "database_connectivity")
  end

  test "should answer 503 when the database answers but the canonical schema is absent" do
    with_readiness(ready: false, checks: { database_connectivity: :ok, schema_presence: :absent }) do
      get "/up"
    end

    assert_response :service_unavailable
    assert_equal "absent", parsed_health.dig("checks", "schema_presence")
  end

  test "should answer 200 when connectivity and schema presence both hold" do
    with_readiness(ready: true, checks: { database_connectivity: :ok, schema_presence: :present }) do
      get "/up"
    end

    assert_response :success
  end

  test "should answer 200 against the real database once the canonical schema is loaded" do
    get "/up"

    assert_response :success
  end

  private

  def with_readiness(ready:, checks:, &block)
    verdict = Kioku::Test::StubReadinessResult.new(ready: ready, checks: checks)
    stub_service = Object.new
    stub_service.define_singleton_method(:call) { verdict }

    Context::Services::Health::Readiness.stub(:new, ->(**) { stub_service }, &block)
  end

  def parsed_health
    JSON.parse(response.body)
  rescue JSON::ParserError
    {}
  end
end
