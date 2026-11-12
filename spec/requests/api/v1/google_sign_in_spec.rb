# frozen_string_literal: true

require "rails_helper"
require "googleauth/id_tokens"

RSpec.describe "API v1 Google sign-in for linked accounts" do
  include ApiAccounts
  around do |example|
    old = ENV.to_h.slice("OAUTH_GOOGLE_SIGN_IN", "GOOGLE_OAUTH_CLIENT_ID")
    ENV["OAUTH_GOOGLE_SIGN_IN"] = "on"
    ENV["GOOGLE_OAUTH_CLIENT_ID"] = "synthetic.apps.googleusercontent.com"
    travel_to(Time.utc(2026, 11, 12, 12)) { with_api_csrf_protection { example.run } }
  ensure
    %w[OAUTH_GOOGLE_SIGN_IN GOOGLE_OAUTH_CLIENT_ID].each { |key| old.key?(key) ? ENV[key] = old[key] : ENV.delete(key) }
  end
  let(:user) { create(:user, password: "password123") }
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }

  before do
    source = Google::Auth::IDTokens::StaticKeySource.new([ Google::Auth::IDTokens::KeyInfo.new(key: key.public_key, algorithm: "RS256") ])
    allow(Google::Auth::IDTokens).to receive(:oidc_key_source).and_return(source)
  end

  def linked_account
    user.oauth_identities.create!(provider: "google", subject: "linked-subject")
  end

  def start_sign_in
    api_csrf
    post api_v1_google_sign_in_start_path, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("data")
  end

  def token(intent, **claims)
    JWT.encode({ iss: "https://accounts.google.com", aud: ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"), sub: "linked-subject",
      nonce: intent.fetch("nonce"), iat: Time.current.to_i, exp: 5.minutes.from_now.to_i }.merge(claims), key, "RS256")
  end

  def complete(intent, id_token = token(intent))
    post api_v1_google_sign_in_complete_path, params: { state: intent.fetch("state"), id_token: }, headers: api_headers, as: :json
  end

  it "requires anonymous browser CSRF and complete default-off configuration" do
    post api_v1_google_sign_in_start_path, as: :json
    expect(response).to have_http_status(:forbidden)
    api_csrf
    ENV["OAUTH_GOOGLE_SIGN_IN"] = "off"
    post api_v1_google_sign_in_start_path, headers: api_headers, as: :json
    expect(response).to have_http_status(:service_unavailable)
    expect(Google::Auth::IDTokens).not_to have_received(:oidc_key_source)
    ENV["OAUTH_GOOGLE_SIGN_IN"] = "on"
    ENV["GOOGLE_OAUTH_CLIENT_ID"] = ""
    expect(Oauth::GoogleSignIn.enabled?).to be(false)
  end

  it "creates a fresh session for the linked subject, rotates CSRF and preserves other sessions" do
    linked_account
    existing = user.sessions.create!
    intent = start_sign_in
    old_csrf = @api_csrf
    complete(intent)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "user", "id")).to eq(user.id)
    @api_csrf = response.parsed_body.dig("data", "csrf_token")
    expect(@api_csrf).not_to eq(old_csrf)
    expect(user.sessions.count).to eq(2)
    expect(existing.reload).to be_persisted
    get api_v1_me_path
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "never creates users or matches email when the verified subject is unlinked" do
    user
    intent = start_sign_in
    expect { complete(intent, token(intent, sub: "unlinked-subject", email: user.email_address, email_verified: true)) }.not_to change(User, :count)
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("OAUTH_INVALID")
    expect(Session.count).to eq(0)
    expect(OauthIdentity.count).to eq(0)
  end

  it "binds to the initiating browser, rejects expiry and requires CSRF on completion" do
    linked_account
    intent = start_sign_in
    post api_v1_google_sign_in_complete_path, params: { state: intent.fetch("state"), id_token: token(intent) }, as: :json
    expect(response).to have_http_status(:forbidden)
    cookies.to_hash.each_key { |name| cookies.delete(name) }
    api_csrf
    complete(intent)
    expect(response).to have_http_status(:unauthorized)
    expect(Google::Auth::IDTokens).not_to have_received(:oidc_key_source)
    intent = start_sign_in
    travel 5.minutes
    complete(intent)
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects changed state, nonce and token claims without authenticating" do
    linked_account
    intent = start_sign_in
    complete(intent.merge("state" => SecureRandom.urlsafe_base64(32)))
    expect(response).to have_http_status(:unauthorized)
    [ { nonce: SecureRandom.urlsafe_base64(32) }, { aud: "other-client" }, { iss: "https://attacker.invalid" } ].each do |claims|
      complete(intent, token(intent, **claims))
      expect(response).to have_http_status(:unauthorized)
    end
    expect(Session.count).to eq(0)
    complete(intent)
    expect(response).to have_http_status(:ok)
  end

  it "rejects account switching and unexpected claim parameters" do
    api_login(user)
    post api_v1_google_sign_in_start_path, headers: api_headers, as: :json
    expect(response).to have_http_status(:conflict)
    post api_v1_google_sign_in_complete_path, params: { state: "x", id_token: "x" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(user.sessions.count).to eq(1)
  end

  it "consumes Redis state once and fails closed when intent state is lost" do
    linked_account
    intent = Oauth::GoogleSignIn.start
    values = { intent: intent.intent, state: intent.state, id_token: token({ "nonce" => intent.nonce }) }
    Oauth::GoogleSignIn.complete(**values) { |account| account.sessions.create! }
    expect { Oauth::GoogleSignIn.complete(**values) { |account| account.sessions.create! } }.to raise_error(Oauth::GoogleLinking::Invalid)
    expect(user.sessions.count).to eq(1)
    intent = Oauth::GoogleSignIn.start
    values = { intent: intent.intent, state: intent.state, id_token: token({ "nonce" => intent.nonce }) }
    FilingsIntel.redis.call("DEL", "oauth:google_sign_in:intent:#{Digest::SHA256.hexdigest(intent.state)}")
    expect { Oauth::GoogleSignIn.complete(**values) { |account| account.sessions.create! } }.to raise_error(Oauth::GoogleLinking::Invalid)
  end

  it "rechecks unlinking during verification and burns intent if session creation fails" do
    row = linked_account
    intent = start_sign_in
    allow(Oauth::GoogleTokenVerifier).to receive(:verify) do
      row.destroy!
      { subject: "linked-subject", nonce: intent.fetch("nonce") }
    end
    complete(intent)
    expect(response).to have_http_status(:unauthorized)
    expect(Session.count).to eq(0)
    allow(Oauth::GoogleTokenVerifier).to receive(:verify).and_call_original
    linked_account
    fresh = Oauth::GoogleSignIn.start
    values = { intent: fresh.intent, state: fresh.state, id_token: token({ "nonce" => fresh.nonce }) }
    expect { Oauth::GoogleSignIn.complete(**values) { raise ActiveRecord::RecordNotSaved } }.to raise_error(ActiveRecord::RecordNotSaved)
    expect { Oauth::GoogleSignIn.complete(**values) { |account| account.sessions.create! } }.to raise_error(Oauth::GoogleLinking::Invalid)
    expect(Session.count).to eq(0)
  end

  it "invalidates replaced challenges and fails closed on Redis failure" do
    linked_account
    first = Oauth::GoogleSignIn.start
    second = Oauth::GoogleSignIn.start(previous_intent: first.intent)
    values = { intent: first.intent, state: first.state, id_token: token({ "nonce" => first.nonce }) }
    expect { Oauth::GoogleSignIn.complete(**values) { |account| account.sessions.create! } }.to raise_error(Oauth::GoogleLinking::Invalid)
    expect(second.state).not_to eq(first.state)
    intent = start_sign_in
    allow(FilingsIntel.redis).to receive(:call).and_call_original
    allow(FilingsIntel.redis).to receive(:call).with("GETDEL", anything).and_raise(RedisClient::Error, "private failure")
    complete(intent)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include("private failure")
    expect(Session.count).to eq(0)
  end

  it "rate limits public initiation and rejects extra parameters" do
    api_csrf
    post api_v1_google_sign_in_start_path, params: { email: "ignored@example.com" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    9.times do
      post api_v1_google_sign_in_start_path, headers: api_headers, as: :json
      expect(response).to have_http_status(:ok)
    end
    post api_v1_google_sign_in_start_path, headers: api_headers, as: :json
    expect(response).to have_http_status(:too_many_requests)
  end
end
