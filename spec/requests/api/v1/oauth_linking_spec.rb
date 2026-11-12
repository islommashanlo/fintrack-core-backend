# frozen_string_literal: true

require "rails_helper"
require "googleauth/id_tokens"

RSpec.describe "API v1 authenticated Google linking" do
  include ApiAccounts
  around do |example|
    old = ENV.to_h.slice("OAUTH_GOOGLE_LINKING", "GOOGLE_OAUTH_CLIENT_ID")
    ENV["OAUTH_GOOGLE_LINKING"] = "on"
    ENV["GOOGLE_OAUTH_CLIENT_ID"] = "synthetic.apps.googleusercontent.com"
    travel_to(Time.utc(2026, 11, 12, 12)) { with_api_csrf_protection { example.run } }
  ensure
    %w[OAUTH_GOOGLE_LINKING GOOGLE_OAUTH_CLIENT_ID].each { |key| old.key?(key) ? ENV[key] = old[key] : ENV.delete(key) }
  end
  let(:user) { create(:user, password: "password123") }
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }

  before do
    source = Google::Auth::IDTokens::StaticKeySource.new([ Google::Auth::IDTokens::KeyInfo.new(key: key.public_key, algorithm: "RS256") ])
    allow(Google::Auth::IDTokens).to receive(:oidc_key_source).and_return(source)
  end

  def start_link
    post api_v1_oauth_link_start_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("data")
  end

  def token(intent, **claims)
    payload = { "iss" => "https://accounts.google.com", "aud" => ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"),
      "sub" => "synthetic-google-subject", "nonce" => intent.fetch("nonce"), "iat" => Time.current.to_i,
      "exp" => 5.minutes.from_now.to_i }.merge(claims.transform_keys(&:to_s))
    JWT.encode(payload.compact, key, "RS256")
  end

  def complete(intent, id_token = token(intent), **extra)
    post api_v1_oauth_link_complete_path, params: { state: intent.fetch("state"), id_token:, **extra }, headers: api_headers, as: :json
  end

  it "requires authentication and CSRF, and stays unavailable without complete configuration" do
    post api_v1_oauth_link_start_path, params: { current_password: "password123" }, as: :json
    expect(response.status).to be_in([ 401, 403 ])
    api_login(user)
    post api_v1_oauth_link_start_path, params: { current_password: "password123" }, as: :json
    expect(response).to have_http_status(:forbidden)
    ENV["OAUTH_GOOGLE_LINKING"] = "off"
    post api_v1_oauth_link_start_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:service_unavailable)
    expect(OauthLinkIntent.count).to eq(0)
    expect(Google::Auth::IDTokens).not_to have_received(:oidc_key_source)
    ENV["OAUTH_GOOGLE_LINKING"] = "on"
    ENV["GOOGLE_OAUTH_CLIENT_ID"] = ""
    expect(Oauth::GoogleLinking.enabled?).to be(false)
  end

  it "confirms the password, links a verified subject and rotates all prior sessions and CSRF" do
    api_login(user)
    post api_v1_oauth_link_start_path, params: { current_password: "wrong" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    intent = start_link
    get api_v1_oauth_identities_path
    expect(response.parsed_body.fetch("meta")).to include("linking_enabled" => true, "sign_in_enabled" => false)
    old_ids = user.sessions.pluck(:id)
    old_csrf = @api_csrf
    complete(intent, token(intent, email: "someone-else@example.com", email_verified: false))
    expect(response).to have_http_status(:ok)
    expect(user.oauth_identities.sole.subject).to eq("synthetic-google-subject")
    expect(user.reload.email_address).not_to eq("someone-else@example.com")
    expect(user.sessions.where(id: old_ids)).not_to exist
    expect(user.sessions.count).to eq(1)
    expect(response.parsed_body.dig("data", "csrf_token")).not_to eq(old_csrf)
    @api_csrf = response.parsed_body.dig("data", "csrf_token")
    complete(intent)
    expect(response).to have_http_status(:unauthorized)
    expect(user.oauth_identities.count).to eq(1)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects token claims and signatures that fail verification without consuming the intent" do
    api_login(user)
    intent = start_link
    [ { iss: "https://attacker.invalid" }, { aud: "other-client" }, { aud: [ ENV.fetch("GOOGLE_OAUTH_CLIENT_ID") ] },
      { exp: Time.current.to_i }, { exp: nil }, { iat: 2.minutes.from_now.to_i }, { azp: "other-client" },
      { nonce: SecureRandom.urlsafe_base64(32) }, { sub: "" } ].each do |claims|
      complete(intent, token(intent, **claims))
      expect(response).to have_http_status(:unauthorized)
      expect(OauthLinkIntent.sole.consumed_at).to be_nil
    end
    complete(intent, JWT.encode({ sub: "forged" }, "secret", "HS256"))
    expect(response).to have_http_status(:unauthorized)
    expect(OauthIdentity.count).to eq(0)
  end

  it "rejects forged state before key access and rejects stale or different-session intents" do
    api_login(user)
    intent = start_link
    complete(intent.merge("state" => SecureRandom.urlsafe_base64(32)))
    expect(response).to have_http_status(:unauthorized)
    expect(Google::Auth::IDTokens).not_to have_received(:oidc_key_source)
    api_login(user)
    complete(intent)
    expect(response).to have_http_status(:unauthorized)
    intent = start_link
    travel 5.minutes
    complete(intent)
    expect(response).to have_http_status(:unauthorized)
  end

  it "never transfers identities or replaces an existing account link and rolls back consumption on conflict" do
    other = create(:user, email_address: "other@example.com")
    other.oauth_identities.create!(provider: "google", subject: "synthetic-google-subject")
    api_login(user)
    intent = start_link
    ids = user.sessions.pluck(:id)
    complete(intent)
    expect(response).to have_http_status(:conflict)
    expect(OauthLinkIntent.sole.consumed_at).to be_nil
    expect(user.sessions.pluck(:id)).to eq(ids)
    user.oauth_identities.create!(provider: "google", subject: "current-subject")
    complete(intent, token(intent, sub: "new-subject"))
    expect(response).to have_http_status(:conflict)
    expect(user.oauth_identities.sole.subject).to eq("current-subject")
    expect(OauthLinkIntent.sole.consumed_at).to be_nil
  end

  it "fails closed when key retrieval fails and never returns token contents" do
    api_login(user)
    intent = start_link
    allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_raise(Google::Auth::IDTokens::KeySourceError, "private error")
    complete(intent)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include("private error", "synthetic-google-subject")
    expect(OauthLinkIntent.sole.consumed_at).to be_nil
  end

  it "rolls back both the identity and intent if session rotation cannot finish" do
    api_login(user)
    intent = start_link
    original_session = user.sessions.sole
    expect do
      Oauth::GoogleLinking.complete(user:, session: original_session, state: intent.fetch("state"), id_token: token(intent)) do
        raise ActiveRecord::RecordNotSaved
      end
    end.to raise_error(ActiveRecord::RecordNotSaved)
    expect(user.oauth_identities).not_to exist
    expect(OauthLinkIntent.sole.consumed_at).to be_nil
    expect(original_session.reload).to be_persisted
  end

  it "rechecks session revocation after provider verification" do
    api_login(user)
    intent = start_link
    allow(Oauth::GoogleTokenVerifier).to receive(:verify) do
      user.sessions.delete_all
      { subject: "synthetic-google-subject", nonce: intent.fetch("nonce") }
    end
    complete(intent)
    expect(response).to have_http_status(:unauthorized)
    expect(OauthIdentity.count).to eq(0)
  end

  it "rejects browser-supplied identity claims and unsupported fields" do
    api_login(user)
    intent = start_link
    complete(intent, token(intent), subject: "forged")
    expect(response).to have_http_status(:bad_request)
    expect(OauthIdentity.count).to eq(0)
    post api_v1_oauth_link_complete_path, params: { state: intent.fetch("state"), id_token: {} }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
  end
end
