# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 origins and request limits" do
  include ApiAccounts

  it "permits credentialed preflights only from the configured exact origin and whitelisted headers/methods" do
    with_frontend_origin("https://app.example.com/") do
      options api_v1_auth_login_path, headers: { "Origin" => "https://app.example.com", "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type, X-CSRF-Token" }
      expect(response).to have_http_status(:no_content)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("https://app.example.com")
      expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
      [ { "Origin" => "https://app.example.com.attacker.test" }, { "Origin" => "null" },
        { "Access-Control-Request-Headers" => "Authorization" }, { "Access-Control-Request-Method" => "PUT" } ].each do |extra|
        options api_v1_auth_login_path, headers: { "Origin" => "https://app.example.com", "Access-Control-Request-Method" => "POST" }.merge(extra)
        expect(response).to have_http_status(:forbidden)
        expect(response.headers["Access-Control-Allow-Credentials"]).to be_nil
      end
    end
  end

  it "does not advertise cross-origin credentials when no frontend origin is configured" do
    with_frontend_origin(nil) do
      get api_v1_plans_path, headers: { "Origin" => "https://untrusted.example" }
      expect(response).to have_http_status(:ok)
      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
      expect(response.headers["Vary"]).to include("Origin")
    end
  end

  it "validates frontend configuration rather than accepting wildcard or path-based origins" do
    [ "*", "https://example.com/path", "https://user:password@example.com", "https://example.com?x=1" ].each do |origin|
      with_frontend_origin(origin) do
        expect { Middleware::ApiCors.origin }.to raise_error(ArgumentError)
      end
    end
  end

  it "throttles public requests by IP while a different IP retains access" do
    300.times { ApiRateLimiter.check!(scope: "ip", identifier: "127.0.0.1", limit: 300, window: 1.minute) }
    get api_v1_plans_path
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"].to_i).to be_between(1, 60)
    other_ip = "192.0.2.1"
    get api_v1_plans_path, env: { "REMOTE_ADDR" => other_ip }
    expect(response).to have_http_status(:ok)
  end

  it "also throttles by authenticated user across different IP addresses" do
    user = create(:user, password: "password123")
    api_login(user)
    300.times { ApiRateLimiter.check!(scope: "user", identifier: user.id, limit: 300, window: 1.minute) }
    get api_v1_me_path, env: { "REMOTE_ADDR" => "192.0.2.10" }
    expect(response).to have_http_status(:too_many_requests)
  end

  it "returns a temporary error if the shared limiter cannot protect authentication" do
    allow(FilingsIntel.redis).to receive(:call).and_raise(RedisClient::ConnectionError, "private infrastructure detail")
    get api_v1_auth_csrf_path
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body.dig("error", "code")).to eq("TEMPORARILY_UNAVAILABLE")
    expect(response.body).not_to include("private infrastructure")
  end

  it "shares credential throttling with the legacy HTML login endpoint" do
    10.times { ApiRateLimiter.check!(scope: "login", identifier: "127.0.0.1", limit: 10, window: 3.minutes) }
    expect do
      post session_path, params: { email_address: "unknown@example.com", password: "incorrect" }
    end.not_to change(Session, :count)
    expect(response).to redirect_to(new_session_url)
  end
end
