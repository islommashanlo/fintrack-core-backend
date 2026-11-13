# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OAuth flow capability discovery" do
  include ApiAccounts
  include OpenapiResponses
  OAUTH_DISCOVERY_ENV_KEYS = %w[OAUTH_GOOGLE_LINKING OAUTH_GOOGLE_SIGN_IN OAUTH_GOOGLE_CODE_FLOW OAUTH_GOOGLE_CODE_LINKING
    GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_OAUTH_REDIRECT_URI GOOGLE_OAUTH_LINK_REDIRECT_URI].freeze

  around do |example|
    old = ENV.to_h.slice(*OAUTH_DISCOVERY_ENV_KEYS)
    OAUTH_DISCOVERY_ENV_KEYS.each { |name| ENV.delete(name) }
    with_api_csrf_protection { example.run }
  ensure
    OAUTH_DISCOVERY_ENV_KEYS.each { |name| old.key?(name) ? ENV[name] = old[name] : ENV.delete(name) }
  end

  def configure
    ENV.update("OAUTH_GOOGLE_LINKING" => "on", "OAUTH_GOOGLE_SIGN_IN" => "on", "OAUTH_GOOGLE_CODE_FLOW" => "on",
      "OAUTH_GOOGLE_CODE_LINKING" => "on", "GOOGLE_OAUTH_CLIENT_ID" => "synthetic.apps.googleusercontent.com",
      "GOOGLE_OAUTH_CLIENT_SECRET" => "synthetic-secret", "GOOGLE_OAUTH_REDIRECT_URI" => "https://app.example/api/v1/auth/google/callback",
      "GOOGLE_OAUTH_LINK_REDIRECT_URI" => "https://app.example/api/v1/me/oauth-identities/google/callback")
  end

  def capabilities
    get api_v1_auth_capabilities_path
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/auth/capabilities")
    response.parsed_body.dig("data", "google")
  end

  def enabled(values)
    [ values.dig("sign_in", "flows", "id_token", "enabled"), values.dig("sign_in", "flows", "authorization_code", "enabled"),
      values.dig("linking", "flows", "id_token", "enabled"), values.dig("linking", "flows", "authorization_code", "enabled") ]
  end

  it "returns public disabled defaults and existing policy without creating account or challenge state" do
    values = capabilities
    expect(enabled(values)).to eq([ false, false, false, false ])
    expect(values).to include("availability" => "configuration_only", "account_creation" => false, "email_matching" => false)
    expect(values.fetch("sign_in")).to include("signed_out_required" => true, "linked_accounts_only" => true)
    expect(values.fetch("linking")).to include("authentication_required" => true, "current_password_required" => true)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.cookies).to be_empty
    expect([ User.count, Session.count, OauthIdentity.count, OauthLinkIntent.count ]).to eq([ 0, 0, 0, 0 ])
    expect(FilingsIntel.redis.call("KEYS", "oauth:*")).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "describes the implemented start and completion methods using local route paths" do
    values = capabilities
    sign_in = values.dig("sign_in", "flows")
    linking = values.dig("linking", "flows")
    expect(sign_in.fetch("id_token")).to include("start" => { "method" => "POST", "path" => api_v1_google_sign_in_start_path },
      "complete" => { "method" => "POST", "path" => api_v1_google_sign_in_complete_path })
    expect(sign_in.fetch("authorization_code")).to include("start" => { "method" => "POST", "path" => api_v1_google_authorize_path },
      "complete" => { "method" => "GET", "path" => api_v1_google_callback_path })
    expect(linking.fetch("id_token")).to include("start" => { "method" => "POST", "path" => api_v1_oauth_link_start_path },
      "complete" => { "method" => "POST", "path" => api_v1_oauth_link_complete_path })
    expect(linking.fetch("authorization_code")).to include("start" => { "method" => "POST", "path" => api_v1_oauth_link_authorize_path },
      "complete" => { "method" => "GET", "path" => api_v1_oauth_link_callback_path })
  end

  it "uses configuration validation without fetching tokens or exposing credentials and registered redirect hosts" do
    configure
    expect(enabled(capabilities)).to eq([ true, true, true, true ])
    expect(response.body).not_to include("synthetic-secret", "synthetic.apps.googleusercontent.com", "app.example",
      "authorization_url", "nonce", "code_verifier", "state_digest")
    expect(FilingsIntel.redis.call("KEYS", "oauth:*")).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "keeps ID-token flow availability independent of code secrets and redirect configuration" do
    configure
    ENV.delete("GOOGLE_OAUTH_CLIENT_SECRET")
    expect(enabled(capabilities)).to eq([ true, false, true, false ])
    ENV["GOOGLE_OAUTH_CLIENT_SECRET"] = "synthetic-secret"
    ENV["GOOGLE_OAUTH_REDIRECT_URI"] = "https://app.example/incorrect"
    expect(enabled(capabilities)).to eq([ true, false, true, true ])
    ENV["GOOGLE_OAUTH_LINK_REDIRECT_URI"] = "https://user@app.example/api/v1/me/oauth-identities/google/callback"
    expect(enabled(capabilities)).to eq([ true, false, true, false ])
  end

  it "reflects independent feature flags immediately without granting eligibility" do
    configure
    ENV["OAUTH_GOOGLE_SIGN_IN"] = "off"
    expect(enabled(capabilities)).to eq([ false, false, true, true ])
    ENV["OAUTH_GOOGLE_LINKING"] = "off"
    expect(enabled(capabilities)).to eq([ false, false, false, false ])
    ENV["OAUTH_GOOGLE_SIGN_IN"] = "on"
    ENV["OAUTH_GOOGLE_CODE_FLOW"] = "off"
    expect(enabled(capabilities)).to eq([ true, false, false, false ])
  end

  it "returns disabled metadata rather than provider errors for invalid client configuration" do
    configure
    ENV["GOOGLE_OAUTH_CLIENT_ID"] = "not-a-google-client"
    expect(enabled(capabilities)).to eq([ false, false, false, false ])
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "is account-independent and does not reveal another user's identity or create linking intents" do
    anonymous = capabilities
    user = create(:user, password: "password123")
    user.oauth_identities.create!(provider: "google", subject: "private-google-subject")
    api_login(user)
    expect(capabilities).to eq(anonymous)
    expect(response.body).not_to include(user.email_address, "private-google-subject", "linked_at")
    expect(OauthLinkIntent.count).to eq(0)
    expect(user.sessions.count).to eq(1)
  end

  it "rejects parameters and remains private on shared throttling or limiter failures" do
    get api_v1_auth_capabilities_path, params: { client_id: "injected" }
    expect(response).to have_http_status(:bad_request)
    expect_documented_response(path: "/auth/capabilities")
    allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Limited.new(30))
    get api_v1_auth_capabilities_path
    expect(response).to have_http_status(:too_many_requests)
    expect_documented_response(path: "/auth/capabilities")
    expect(response.headers["Cache-Control"]).to include("no-store")
    allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Unavailable)
    get api_v1_auth_capabilities_path
    expect(response).to have_http_status(:service_unavailable)
    expect_documented_response(path: "/auth/capabilities")
    expect(response.headers["Cache-Control"]).to include("no-store")
  end
end
