# frozen_string_literal: true

# GET /health: readiness. Unlike /up (is the process alive), this checks that the
# services every request and job depends on are reachable.
class HealthController < ActionController::API
  def show
    checks = { database: database_ok?, redis: redis_ok? }
    healthy = checks.values.all?

    render json: { status: healthy ? "ok" : "unavailable", checks: checks.transform_values { |ok| ok ? "ok" : "down" } },
           status: healthy ? :ok : :service_unavailable
  end

  private

  def database_ok?
    ActiveRecord::Base.connection.select_value("SELECT 1") == 1
  rescue StandardError
    false
  end

  def redis_ok?
    FilingsIntel.redis.call("PING") == "PONG"
  rescue StandardError
    false
  end
end
