# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 account authentication" do
  include ApiAccounts
  around { |example| with_api_csrf_protection { example.run } }
  let(:password) { "password123" }

  it "signs up with normalized email and a protected cookie and returns only public account fields" do
    api_csrf
    initial_token = @api_csrf
    expect do
      post api_v1_auth_signup_path, params: { email: "  Reader@Example.com ", password:, password_confirmation: password },
           headers: api_headers, as: :json
    end.to change(User, :count).by(1).and change(Session, :count).by(1)

    expect(response).to have_http_status(:created)
    body = response.parsed_body.fetch("data")
    expect(body.fetch("user")).to include("email" => "reader@example.com", "plan" => "free", "limits" => include("watchlist_items" => 15))
    expect(body.fetch("user").keys).to contain_exactly("id", "email", "created_at", "plan", "limits")
    expect(body.fetch("csrf_token")).not_to eq(initial_token)
    cookie = Array(response.headers["Set-Cookie"]).join("\n")
    expect(cookie).to include("session_id=", "httponly", "samesite=lax")
    expect(response.headers["Cache-Control"]).to eq("no-store")

    get api_v1_me_path
    expect(response.parsed_body.dig("data", "email")).to eq("reader@example.com")
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "sets a Secure session cookie over HTTPS" do
    user = create(:user, password:)
    https!
    api_login(user)
    expect(Array(response.headers["Set-Cookie"]).join("\n")).to include("secure")
  end

  it "rotates the browser session at login and invalidates it at logout" do
    user = create(:user, password:)
    api_login(user)
    first_id = user.sessions.sole.id
    first_cookie = cookies[:session_id]
    api_login(user)
    expect(user.sessions.count).to eq(1)
    expect(user.sessions.sole.id).not_to eq(first_id)
    expect(cookies[:session_id]).not_to eq(first_cookie)

    delete api_v1_auth_logout_path, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(user.sessions.count).to eq(0)
    get api_v1_me_path
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("UNAUTHENTICATED")
    expect(response).not_to be_redirect
  end

  it "rejects both unknown accounts and wrong passwords with the same response" do
    user = create(:user, password:)
    api_csrf
    post api_v1_auth_login_path, params: { email: "unknown@example.com", password: "incorrect" }, headers: api_headers, as: :json
    unknown = response.parsed_body
    post api_v1_auth_login_path, params: { email: user.email_address, password: "incorrect" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq(unknown)
    expect(Session.count).to eq(0)
  end

  it "rejects missing or foreign CSRF tokens on unauthenticated login and signup" do
    user = create(:user, password:)
    api_csrf
    expect do
      post api_v1_auth_login_path, params: { email: user.email_address, password: }, as: :json
    end.not_to change(Session, :count)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("INVALID_CSRF_TOKEN")
    post api_v1_auth_signup_path, params: { email: "new@example.com", password: }, headers: { "X-CSRF-Token" => "invalid" }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects a token from another browser even when the request origin matches" do
    user = create(:user, password:)
    api_csrf
    other_browser = ActionDispatch::Integration::Session.new(Rails.application)
    other_browser.post(api_v1_auth_login_path, params: { email: user.email_address, password: }, headers: api_headers, as: :json)
    expect(other_browser.response).to have_http_status(:forbidden)
    expect(Session.count).to eq(0)
  end

  it "rejects foreign and null origins even with a valid CSRF token" do
    user = create(:user, password:)
    api_csrf
    [ "https://untrusted.example", "null" ].each do |origin|
      post api_v1_auth_login_path, params: { email: user.email_address, password: }, headers: api_headers.merge("Origin" => origin), as: :json
      expect(response).to have_http_status(:forbidden)
    end
    expect(Session.count).to eq(0)
  end

  it "allows the configured frontend origin with a valid CSRF token and credentialed CORS" do
    user = create(:user, password:)
    with_frontend_origin("https://app.example.com") do
      api_csrf
      post api_v1_auth_login_path, params: { email: user.email_address, password: },
           headers: api_headers.merge("Origin" => "https://app.example.com"), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("https://app.example.com")
      expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
    end
  end

  it "rejects invalid accounts and attempts to set subscription state through signup" do
    api_csrf
    [ { email: "invalid", password: }, { email: "new@example.com", password: "short" },
      { email: "new@example.com", password:, password_confirmation: "different" } ].each do |values|
      post api_v1_auth_signup_path, params: values, headers: api_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
    post api_v1_auth_signup_path, params: { email: "new@example.com", password:, plan: "pro" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(User.count).to eq(0)
  end

  it "rejects duplicate email addresses after normalization without creating another session" do
    create(:user, email_address: "reader@example.com", password:)
    api_csrf
    expect do
      post api_v1_auth_signup_path, params: { email: " READER@example.com ", password: }, headers: api_headers, as: :json
    end.not_to change(Session, :count)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "does not authenticate an expired or tampered session cookie" do
    user = create(:user, password:)
    api_login(user)
    user.sessions.sole.update!(created_at: 31.days.ago)
    get api_v1_me_path
    expect(response).to have_http_status(:unauthorized)
    cookies[:session_id] = "invalid-cookie"
    get api_v1_me_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "requires the current password to change account credentials and revokes other sessions" do
    user = create(:user, password:)
    other_session = user.sessions.create!
    api_login(user)
    patch api_v1_me_path, params: { email: "changed@example.com", current_password: "incorrect" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(user.reload.email_address).not_to eq("changed@example.com")

    patch api_v1_me_path, params: { email: "changed@example.com", password: "replacement123", current_password: password }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "user", "email")).to eq("changed@example.com")
    expect(Session.exists?(other_session.id)).to be(false)
    expect(user.sessions.count).to eq(1)
    expect(user.reload.authenticate("replacement123")).to be_truthy
  end

  it "requires CSRF protection on account changes and logout" do
    user = create(:user, password:)
    api_login(user)
    patch api_v1_me_path, params: { email: "changed@example.com", current_password: password }, as: :json
    expect(response).to have_http_status(:forbidden)
    delete api_v1_auth_logout_path, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(user.sessions.count).to eq(1)
  end

  it "removes only the authenticated account's private records and preserves filed data" do
    user = create(:user, password:)
    other = create(:user, email_address: "other@example.com", password:)
    filing = create(:filing)
    follow = create(:follow, user:)
    delivery = create(:alert_delivery, alert_rule: follow.alert_rule, filing:)
    create(:follow, user: other)
    api_login(user)
    delete api_v1_me_path, params: { current_password: password }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(User.exists?(user.id)).to be(false)
    expect(AlertDelivery.exists?(delivery.id)).to be(false)
    expect(other.follows.count).to eq(1)
    expect(Filing.exists?(filing.id)).to be(true)
    get api_v1_me_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "throttles credential attempts across clients with a Retry-After header" do
    api_csrf
    10.times do
      post api_v1_auth_login_path, params: { email: "unknown@example.com", password: "incorrect" }, headers: api_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
    post api_v1_auth_login_path, params: { email: "unknown@example.com", password: "incorrect" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"].to_i).to be_between(1, 180)
    expect(response.parsed_body.dig("error", "code")).to eq("RATE_LIMITED")
  end

  it "uses a shared plan catalog without enabling Pro from request data" do
    get api_v1_plans_path
    expect(response.parsed_body.fetch("data")).to include(
      include("id" => "free", "limits" => include("watchlist_items" => 15, "alert_rules" => 3)),
      include("id" => "pro", "limits" => include("watchlist_items" => nil, "instant_alerts" => true))
    )
  end
end
