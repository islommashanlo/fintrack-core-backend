# frozen_string_literal: true

require "rails_helper"
require "googleauth/id_tokens"

RSpec.describe "Google authorization-code sign-in" do
  include ApiAccounts
  include OpenapiResponses
  SETTINGS = %w[OAUTH_GOOGLE_SIGN_IN OAUTH_GOOGLE_CODE_FLOW GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_OAUTH_REDIRECT_URI].freeze
  around do |example|
    old = ENV.to_h.slice(*SETTINGS)
    ENV.update("OAUTH_GOOGLE_SIGN_IN" => "on", "OAUTH_GOOGLE_CODE_FLOW" => "on",
      "GOOGLE_OAUTH_CLIENT_ID" => "synthetic.apps.googleusercontent.com", "GOOGLE_OAUTH_CLIENT_SECRET" => "synthetic-secret",
      "GOOGLE_OAUTH_REDIRECT_URI" => "https://www.example.com/api/v1/auth/google/callback")
    travel_to(Time.utc(2026, 11, 13, 12)) { with_api_csrf_protection { example.run } }
  ensure
    SETTINGS.each { |name| old.key?(name) ? ENV[name] = old[name] : ENV.delete(name) }
  end
  let(:user) { create(:user, password: "password123") }
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  before do
    source = Google::Auth::IDTokens::StaticKeySource.new([ Google::Auth::IDTokens::KeyInfo.new(key: key.public_key, algorithm: "RS256") ])
    allow(Google::Auth::IDTokens).to receive(:oidc_key_source).and_return(source)
    user.oauth_identities.create!(provider: "google", subject: "linked-subject")
  end

  def authorize
    api_csrf
    post api_v1_google_authorize_path, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/auth/google/authorize", method: :post)
    URI.decode_www_form(URI.parse(response.parsed_body.dig("data", "authorization_url")).query).to_h
  end

  def token(parameters, **claims)
    JWT.encode({ iss: "https://accounts.google.com", aud: ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"), sub: "linked-subject",
      nonce: parameters.fetch("nonce"), iat: Time.current.to_i, exp: 5.minutes.from_now.to_i }.merge(claims), key, "RS256")
  end

  def provider(parameters, **claims)
    stub_request(:post, Oauth::GoogleCodeExchange::TOKEN_ENDPOINT)
      .to_return(status: 200, body: { id_token: token(parameters, **claims), access_token: "discard-this-access-token" }.to_json,
        headers: { "Content-Type" => "application/json" })
  end

  def callback(parameters, **extra)
    get api_v1_google_callback_path, params: { state: parameters.fetch("state"), code: "synthetic-code", **extra }
  end

  it "exchanges a code with bound PKCE, signs in only its linked subject and rotates CSRF" do
    existing = user.sessions.create!
    parameters = authorize
    old_csrf = @api_csrf
    expect(parameters).to include("response_type" => "code", "scope" => "openid", "code_challenge_method" => "S256")
    expect(parameters).not_to have_key("client_secret")
    exchange = provider(parameters).with do |request|
      body = URI.decode_www_form(request.body).to_h
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(body.fetch("code_verifier")), padding: false)
      body.slice("client_id", "client_secret", "redirect_uri", "grant_type", "code") == {
        "client_id" => ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"), "client_secret" => "synthetic-secret",
        "redirect_uri" => ENV.fetch("GOOGLE_OAUTH_REDIRECT_URI"), "grant_type" => "authorization_code", "code" => "synthetic-code"
      } && challenge == parameters.fetch("code_challenge")
    end
    callback(parameters, scope: "openid", authuser: "0", prompt: "consent", iss: "https://accounts.google.com")
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/auth/google/callback")
    expect(response.parsed_body.dig("data", "user", "id")).to eq(user.id)
    expect(response.parsed_body.dig("data", "csrf_token")).not_to eq(old_csrf)
    expect(response.body).not_to include("discard-this-access-token", "synthetic-secret", "synthetic-code")
    expect(response.headers).to include("Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer")
    expect(existing.reload).to be_persisted
    expect(user.sessions.count).to eq(2)
    expect(exchange).to have_been_requested.once
  end

  it "requires browser CSRF for authorization and fails closed on disabled or incomplete configuration" do
    post api_v1_google_authorize_path, as: :json
    expect(response).to have_http_status(:forbidden)
    api_csrf
    %w[OAUTH_GOOGLE_SIGN_IN OAUTH_GOOGLE_CODE_FLOW GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_OAUTH_REDIRECT_URI].each do |name|
      previous = ENV[name]
      ENV[name] = ""
      post api_v1_google_authorize_path, headers: api_headers, as: :json
      expect(response).to have_http_status(:service_unavailable)
      expect_documented_response(path: "/auth/google/authorize", method: :post)
      ENV[name] = previous
    end
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects insecure, credentialed, query-bearing and arbitrary callback paths" do
    api_csrf
    [ "http://public.example/api/v1/auth/google/callback", "https://user@example.com/api/v1/auth/google/callback",
      "https://example.com/elsewhere", "https://example.com/api/v1/auth/google/callback?next=evil", "https://example.com/api/v1/auth/google/callback#fragment" ].each do |uri|
      ENV["GOOGLE_OAUTH_REDIRECT_URI"] = uri
      post api_v1_google_authorize_path, headers: api_headers, as: :json
      expect(response).to have_http_status(:service_unavailable)
    end
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects absent, wrong, expired and replaced browser states before contacting the provider" do
    first = authorize
    latest = authorize
    callback(first)
    expect(response).to have_http_status(:unauthorized)
    callback(latest.merge("state" => SecureRandom.urlsafe_base64(32)))
    expect(response).to have_http_status(:unauthorized)
    travel 6.minutes
    callback(latest)
    expect(response).to have_http_status(:unauthorized)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects another browser and preserves the initiating browser's challenge" do
    parameters = authorize
    other = ActionDispatch::Integration::Session.new(Rails.application)
    other.get api_v1_google_callback_path, params: { state: parameters.fetch("state"), code: "synthetic-code" }
    expect(other.response).to have_http_status(:unauthorized)
    exchange = provider(parameters)
    callback(parameters)
    expect(response).to have_http_status(:ok)
    expect(exchange).to have_been_requested.once
  end

  it "does not allow code challenges to complete through the existing ID-token endpoint" do
    parameters = authorize
    post api_v1_google_sign_in_complete_path, params: { state: parameters.fetch("state"), id_token: token(parameters) }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    provider(parameters)
    callback(parameters)
    expect(response).to have_http_status(:ok)
  end

  it "does not allow an ID-token challenge through the code callback" do
    api_csrf
    post api_v1_google_sign_in_start_path, headers: api_headers, as: :json
    callback(response.parsed_body.fetch("data"))
    expect(response).to have_http_status(:unauthorized)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "burns denied, failed and replayed attempts without returning provider details" do
    parameters = authorize
    get api_v1_google_callback_path, params: { state: parameters.fetch("state"), error: "access_denied", error_description: "private-provider-message" }
    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include("private-provider-message")
    callback(parameters)
    expect(response).to have_http_status(:unauthorized)
    fresh = authorize
    exchange = stub_request(:post, Oauth::GoogleCodeExchange::TOKEN_ENDPOINT).to_return(status: 400, body: "private-provider-message")
    2.times { callback(fresh) }
    expect(response).to have_http_status(:unauthorized)
    expect(exchange).to have_been_requested.once
    expect(Session.count).to eq(0)
  end

  it "rejects unlinked subjects, wrong nonces and invalid audiences without creating accounts" do
    [ { sub: "unlinked-subject", email: user.email_address }, { nonce: SecureRandom.urlsafe_base64(32) }, { aud: "wrong-client" } ].each do |claims|
      parameters = authorize
      provider(parameters, **claims)
      expect { callback(parameters) }.not_to change(User, :count)
      expect(response).to have_http_status(:unauthorized)
    end
    expect(Session.count).to eq(0)
  end

  it "handles redirects, oversized and malformed provider responses without retrying" do
    [ { status: 503 }, { status: 302, headers: { "Location" => "https://attacker.invalid" } },
      { status: 200, body: "x" * 65_537 }, { status: 200, body: "{" }, { status: 200, body: '{}' } ].each_with_index do |result, index|
      parameters = authorize
      code = "synthetic-code-#{index}"
      exchange = stub_request(:post, Oauth::GoogleCodeExchange::TOKEN_ENDPOINT).with(body: hash_including("code" => code)).to_return(result)
      callback(parameters, code:)
      expect(response).to have_http_status(:service_unavailable)
      callback(parameters, code:)
      expect(response).to have_http_status(:unauthorized)
      expect(exchange).to have_been_requested.once
    end
    expect(Session.count).to eq(0)
    expect(WebMock).not_to have_requested(:any, /attacker.invalid/)
  end

  it "fails closed on provider timeout without a session or automatic retry" do
    parameters = authorize
    exchange = stub_request(:post, Oauth::GoogleCodeExchange::TOKEN_ENDPOINT).to_timeout
    callback(parameters)
    expect(response).to have_http_status(:service_unavailable)
    expect(Session.count).to eq(0)
    expect(exchange).to have_been_requested.once
  end

  it "rechecks feature revocation after token verification before creating a session" do
    parameters = authorize
    provider(parameters)
    allow(Oauth::GoogleTokenVerifier).to receive(:verify).and_wrap_original do |method, *args, **keywords|
      claims = method.call(*args, **keywords)
      ENV["OAUTH_GOOGLE_CODE_FLOW"] = "off"
      claims
    end
    callback(parameters)
    expect(response).to have_http_status(:service_unavailable)
    expect(Session.count).to eq(0)
  end

  it "burns a claimed code intent when session creation rolls back" do
    result = Oauth::GoogleAuthorization.start
    parameters = URI.decode_www_form(URI.parse(result.authorization_url).query).to_h
    exchange = provider(parameters)
    values = { intent: result.intent, state: parameters.fetch("state"), code: "synthetic-code" }
    expect do
      Oauth::GoogleAuthorization.complete(**values) { raise ActiveRecord::RecordNotSaved }
    end.to raise_error(ActiveRecord::RecordNotSaved)
    expect { Oauth::GoogleAuthorization.complete(**values) { |account| account.sessions.create! } }.to raise_error(Oauth::GoogleLinking::Invalid)
    expect(Session.count).to eq(0)
    expect(exchange).to have_been_requested.once
  end

  it "rejects changed configuration and signed-in account switching before exchanging codes" do
    parameters = authorize
    ENV["GOOGLE_OAUTH_CLIENT_SECRET"] = "changed-secret"
    callback(parameters)
    expect(response).to have_http_status(:unauthorized)
    ENV["GOOGLE_OAUTH_CLIENT_SECRET"] = "synthetic-secret"
    api_login(user)
    callback(parameters)
    expect(response).to have_http_status(:conflict)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "fails closed on Redis outage or lost state before any code exchange" do
    parameters = authorize
    allow(FilingsIntel.redis).to receive(:call).and_call_original
    allow(FilingsIntel.redis).to receive(:call).with("GETDEL", anything).and_raise(RedisClient::Error, "private-cache-message")
    callback(parameters)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include("private-cache-message")
    allow(FilingsIntel.redis).to receive(:call).with("GETDEL", anything).and_return(nil)
    callback(parameters)
    expect(response).to have_http_status(:unauthorized)
    expect(Session.count).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "sets no-referrer and no-store even when shared request limiting fails first" do
    api_csrf
    allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Unavailable)
    get api_v1_google_callback_path, params: { state: "private-state", code: "private-code" }
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers).to include("Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rate limits authorization attempts without contacting Google" do
    api_csrf
    10.times do
      post api_v1_google_authorize_path, headers: api_headers, as: :json
      expect(response).to have_http_status(:ok)
    end
    post api_v1_google_authorize_path, headers: api_headers, as: :json
    expect(response).to have_http_status(:too_many_requests)
    expect_documented_response(path: "/auth/google/authorize", method: :post)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects unexpected, duplicate, oversized and mixed success/error callback parameters" do
    parameters = authorize
    [ { subject: "injected" }, { code: "x" * 4097 }, { error: "access_denied" }, { iss: "https://attacker.invalid" } ].each do |values|
      callback(parameters, **values)
      expect(response.status).to be_in([ 400, 401 ])
    end
    query = URI.encode_www_form(state: parameters.fetch("state"), code: "synthetic-code")
    get "#{api_v1_google_callback_path}?#{query}&state=duplicate"
    expect(response).to have_http_status(:bad_request)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
