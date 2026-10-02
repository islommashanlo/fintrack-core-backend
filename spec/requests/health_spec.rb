# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Health checks" do
  it "answers the liveness probe" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end

  it "reports ready when Postgres and Redis answer" do
    get "/health"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok", "checks" => { "database" => "ok", "redis" => "ok" })
  end

  it "answers 503 and says which dependency is down" do
    allow(FilingsIntel.redis).to receive(:call).with("PING").and_raise(RedisClient::CannotConnectError)

    get "/health"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("status" => "unavailable", "checks" => { "database" => "ok", "redis" => "down" })
  end

  it "does not require a modern browser" do
    get "/health", headers: { "User-Agent" => "curl/8.5.0" }

    expect(response).to have_http_status(:ok)
  end
end
