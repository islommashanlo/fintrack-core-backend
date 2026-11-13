# frozen_string_literal: true

require "rails_helper"
require "googleauth/id_tokens"

RSpec.describe "Password-confirmed Google code linking" do
  include ApiAccounts
  include OpenapiResponses
  LINK_CODE_ENV_KEYS = %w[OAUTH_GOOGLE_LINKING OAUTH_GOOGLE_CODE_LINKING OAUTH_GOOGLE_SIGN_IN OAUTH_GOOGLE_CODE_FLOW
    GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_OAUTH_LINK_REDIRECT_URI].freeze
  around do |example|
    old = ENV.to_h.slice(*LINK_CODE_ENV_KEYS)
    ENV.update("OAUTH_GOOGLE_LINKING" => "on", "OAUTH_GOOGLE_CODE_LINKING" => "on", "OAUTH_GOOGLE_SIGN_IN" => "off",
      "OAUTH_GOOGLE_CODE_FLOW" => "off", "GOOGLE_OAUTH_CLIENT_ID" => "synthetic.apps.googleusercontent.com",
      "GOOGLE_OAUTH_CLIENT_SECRET" => "synthetic-secret", "GOOGLE_OAUTH_LINK_REDIRECT_URI" => "https://www.example.com/api/v1/me/oauth-identities/google/callback")
    travel_to(Time.utc(2026, 11, 13, 12)) { with_api_csrf_protection { example.run } }
  ensure
    LINK_CODE_ENV_KEYS.each { |name| old.key?(name) ? ENV[name] = old[name] : ENV.delete(name) }
  end
  let(:user) { create(:user, password: "password123") }
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  before do
    source = Google::Auth::IDTokens::StaticKeySource.new([ Google::Auth::IDTokens::KeyInfo.new(key: key.public_key, algorithm: "RS256") ])
    allow(Google::Auth::IDTokens).to receive(:oidc_key_source).and_return(source)
    api_login(user)
  end

  def authorize
    api_csrf
    post api_v1_oauth_link_authorize_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/me/oauth-identities/google/authorize", method: :post)
    URI.decode_www_form(URI.parse(response.parsed_body.dig("data", "authorization_url")).query).to_h
  end

  def token(parameters, **claims)
    JWT.encode({ iss: "https://accounts.google.com", aud: ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"), sub: "link-subject",
      nonce: parameters.fetch("nonce"), iat: Time.current.to_i, exp: 5.minutes.from_now.to_i }.merge(claims), key, "RS256")
  end

  def provider(parameters, **claims)
    stub_request(:post, Oauth::GoogleCodeExchange::TOKEN_ENDPOINT).to_return(status: 200,
      body: { id_token: token(parameters, **claims), access_token: "discarded-access-token" }.to_json)
  end

  def callback(parameters, **extra)
    get api_v1_oauth_link_callback_path, params: { state: parameters.fetch("state"), code: "synthetic-code", **extra }
  end

  it "links a verified subject with bound PKCE and atomically replaces all prior sessions" do
    user.sessions.create!
    original = user.sessions.pluck(:id)
    parameters = authorize
    csrf = @api_csrf
    expect(OauthLinkIntent.sole.flow).to eq("code")
    expect(parameters).to include("scope" => "openid", "redirect_uri" => ENV.fetch("GOOGLE_OAUTH_LINK_REDIRECT_URI"))
    exchange = provider(parameters, email: "different@example.com").with do |request|
      body = URI.decode_www_form(request.body).to_h
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(body.fetch("code_verifier")), padding: false)
      body["redirect_uri"] == parameters.fetch("redirect_uri") && body["client_secret"] == "synthetic-secret" && challenge == parameters.fetch("code_challenge")
    end
    callback(parameters)
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/me/oauth-identities/google/callback")
    expect(response.parsed_body.dig("data", "csrf_token")).not_to eq(csrf)
    expect(response.headers).to include("Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer")
    expect(response.body).not_to include("synthetic-secret", "synthetic-code", "discarded-access-token")
    expect(user.oauth_identities.sole.subject).to eq("link-subject")
    expect(user.reload.email_address).not_to eq("different@example.com")
    expect(user.sessions.count).to eq(1)
    expect(user.sessions.pluck(:id) & original).to be_empty
    expect(OauthLinkIntent.count).to eq(0)
    expect(exchange).to have_been_requested.once
  end

  it "requires authentication, CSRF and a correct password before issuing a code intent" do
    post api_v1_oauth_link_authorize_path, params: { current_password: "password123" }, as: :json
    expect(response).to have_http_status(:forbidden)
    post api_v1_oauth_link_authorize_path, params: { current_password: "wrong" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect_documented_response(path: "/me/oauth-identities/google/authorize", method: :post)
    other = ActionDispatch::Integration::Session.new(Rails.application)
    other.get api_v1_oauth_link_callback_path, params: { state: "x", code: "x" }
    expect(other.response).to have_http_status(:unauthorized)
    expect(OauthLinkIntent.count).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "stays unavailable with disabled or incomplete configuration" do
    %w[OAUTH_GOOGLE_LINKING OAUTH_GOOGLE_CODE_LINKING GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_OAUTH_LINK_REDIRECT_URI].each do |name|
      previous = ENV[name]
      ENV[name] = ""
      post api_v1_oauth_link_authorize_path, params: { current_password: "password123" }, headers: api_headers, as: :json
      expect(response).to have_http_status(:service_unavailable)
      ENV[name] = previous
    end
    expect(OauthLinkIntent.count).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "does not transfer a subject owned by another user and burns its exchange gate on conflict" do
    other = create(:user, email_address: "foreign-code@example.com")
    other.oauth_identities.create!(provider: "google", subject: "link-subject")
    original = user.sessions.pluck(:id)
    parameters = authorize
    exchange = provider(parameters)
    callback(parameters)
    expect(response).to have_http_status(:conflict)
    expect_documented_response(path: "/me/oauth-identities/google/callback")
    expect(response.body).not_to include(other.email_address)
    expect(user.oauth_identities.count).to eq(0)
    expect(OauthLinkIntent.sole.consumed_at).to be_nil
    expect(user.sessions.pluck(:id)).to eq(original)
    callback(parameters)
    expect(response).to have_http_status(:unauthorized)
    expect(exchange).to have_been_requested.once
  end

  it "does not replace a different identity already linked to the account" do
    identity = user.oauth_identities.create!(provider: "google", subject: "existing-subject")
    parameters = authorize
    provider(parameters)
    callback(parameters)
    expect(response).to have_http_status(:conflict)
    expect(identity.reload.subject).to eq("existing-subject")
    expect(user.sessions.count).to eq(1)
  end

  it "keeps linking the same subject idempotent while rotating sessions" do
    identity = user.oauth_identities.create!(provider: "google", subject: "link-subject")
    2.times do
      parameters = authorize
      provider(parameters)
      callback(parameters)
      expect(response).to have_http_status(:ok)
      expect(user.oauth_identities.sole.id).to eq(identity.id)
      expect(user.sessions.count).to eq(1)
    end
  end

  it "binds code completion to the original active session even for the same account" do
    active = user.sessions.sole
    result = Oauth::GoogleCodeLinking.start(user:, session: active, current_password: "password123")
    parameters = URI.decode_www_form(URI.parse(result.authorization_url).query).to_h
    values = { user:, session: user.sessions.create!, intent: result.intent, state: parameters.fetch("state"), code: "synthetic-code" }
    expect { Oauth::GoogleCodeLinking.complete(**values) }.to raise_error(Oauth::GoogleLinking::Invalid)
    exchange = provider(parameters)
    Oauth::GoogleCodeLinking.complete(**values.merge(session: active))
    expect(user.oauth_identities.sole.subject).to eq("link-subject")
    expect(exchange).to have_been_requested.once
  end

  it "isolates legacy ID-token intents from code completion and invalidates replaced challenges" do
    first = authorize
    post api_v1_oauth_link_complete_path, params: { state: first.fetch("state"), id_token: token(first) }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    post api_v1_oauth_link_start_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    legacy = response.parsed_body.fetch("data")
    callback(first)
    expect(response).to have_http_status(:unauthorized)
    callback(legacy)
    expect(response).to have_http_status(:unauthorized)
    expect(WebMock).not_to have_requested(:any, /./)
    second = authorize
    post api_v1_oauth_link_complete_path, params: { state: legacy.fetch("state"), id_token: token(legacy) }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    provider(second)
    callback(second)
    expect(response).to have_http_status(:ok)
  end

  it "rejects expired, wrong and replayed states before provider exchange" do
    parameters = authorize
    callback(parameters.merge("state" => SecureRandom.urlsafe_base64(32)))
    expect(response).to have_http_status(:unauthorized)
    travel 5.minutes
    callback(parameters)
    expect(response).to have_http_status(:unauthorized)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "burns provider-denied and failed exchanges without changing account sessions" do
    denied = authorize
    get api_v1_oauth_link_callback_path, params: { state: denied.fetch("state"), error: "access_denied", error_description: "private-provider-message" }
    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include("private-provider-message")
    callback(denied)
    expect(response).to have_http_status(:unauthorized)
    fresh = authorize
    exchange = stub_request(:post, Oauth::GoogleCodeExchange::TOKEN_ENDPOINT).to_timeout
    callback(fresh)
    expect(response).to have_http_status(:service_unavailable)
    callback(fresh)
    expect(response).to have_http_status(:unauthorized)
    expect(exchange).to have_been_requested.once
    expect(user.oauth_identities.count).to eq(0)
    expect(user.sessions.count).to eq(1)
  end

  it "rejects invalid verified nonces and audiences without creating identities" do
    [ { nonce: SecureRandom.urlsafe_base64(32) }, { aud: "wrong-client" } ].each do |claims|
      parameters = authorize
      provider(parameters, **claims)
      callback(parameters)
      expect(response).to have_http_status(:unauthorized)
    end
    expect(user.oauth_identities.count).to eq(0)
  end

  it "rechecks session revocation during verification" do
    parameters = authorize
    provider(parameters)
    allow(Oauth::GoogleTokenVerifier).to receive(:verify).and_wrap_original do |method, *args, **keywords|
      claims = method.call(*args, **keywords)
      user.sessions.delete_all
      claims
    end
    callback(parameters)
    expect(response).to have_http_status(:unauthorized)
    expect(user.oauth_identities.count).to eq(0)
    expect(user.sessions.count).to eq(0)
  end

  it "rolls back identity changes when configuration is revoked during verification" do
    parameters = authorize
    provider(parameters)
    allow(Oauth::GoogleTokenVerifier).to receive(:verify).and_wrap_original do |method, *args, **keywords|
      claims = method.call(*args, **keywords)
      ENV["OAUTH_GOOGLE_CODE_LINKING"] = "off"
      claims
    end
    callback(parameters)
    expect(response).to have_http_status(:service_unavailable)
    expect(user.oauth_identities.count).to eq(0)
    expect(user.sessions.count).to eq(1)
    expect(OauthLinkIntent.sole.consumed_at).to be_nil
  end

  it "keeps the exchange consumed when identity/session work rolls back" do
    active = user.sessions.sole
    result = Oauth::GoogleCodeLinking.start(user:, session: active, current_password: "password123")
    parameters = URI.decode_www_form(URI.parse(result.authorization_url).query).to_h
    exchange = provider(parameters)
    values = { user:, session: active, intent: result.intent, state: parameters.fetch("state"), code: "synthetic-code" }
    expect { Oauth::GoogleCodeLinking.complete(**values) { raise ActiveRecord::RecordNotSaved } }.to raise_error(ActiveRecord::RecordNotSaved)
    expect(user.oauth_identities.count).to eq(0)
    expect(OauthLinkIntent.sole.consumed_at).to be_nil
    expect { Oauth::GoogleCodeLinking.complete(**values) }.to raise_error(Oauth::GoogleLinking::Invalid)
    expect(exchange).to have_been_requested.once
  end

  it "fails closed on missing or unavailable Redis gates before exchange" do
    parameters = authorize
    allow(FilingsIntel.redis).to receive(:call).and_call_original
    allow(FilingsIntel.redis).to receive(:call).with("GETDEL", anything).and_raise(RedisClient::Error, "private-cache-message")
    callback(parameters)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include("private-cache-message")
    allow(FilingsIntel.redis).to receive(:call).with("GETDEL", anything).and_return(nil)
    callback(parameters)
    expect(response).to have_http_status(:unauthorized)
    expect(user.oauth_identities.count).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rate limits code callbacks and retains private response headers" do
    parameters = authorize.merge("state" => SecureRandom.urlsafe_base64(32))
    10.times do
      callback(parameters)
      expect(response).to have_http_status(:unauthorized)
    end
    callback(parameters)
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers).to include("Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "retains no-referrer when shared request limiting fails first" do
    allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Unavailable)
    callback({ "state" => "private-state" })
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers).to include("Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer")
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
