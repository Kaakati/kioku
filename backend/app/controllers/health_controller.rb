# frozen_string_literal: true

# GET /up is readiness, not liveness (plan 3.1). It answers 200 only after the
# readiness service confirms database connectivity AND canonical schema
# presence, and 503 otherwise. The controller translates HTTP: the verdict is
# the service's.
class HealthController < ActionController::API
  def show
    result = Context::Services::Health::Readiness.new.call

    render json: {
      "status" => result.ready? ? "ready" : "not_ready",
      "checks" => result.checks.transform_values(&:to_s)
    }, status: result.ready? ? :ok : :service_unavailable
  end
end
