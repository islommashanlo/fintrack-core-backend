# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 OAuth identity management" do
  include ApiAccounts
  around { |example| with_api_csrf_protection { example.run } }
  let(:user) { create(:user, password: "password123") }

  def identity(owner = user, subject: "synthetic-subject")
    owner.oauth_identities.create!(provider: "google", subject:)
  end

  it "requires authentication and returns only owned metadata without enabling external authentication" do
    get api_v1_oauth_identities_path
    expect(response).to have_http_status(:unauthorized)
    row = identity
    other = create(:user, email_address: "other@example.com")
    identity(other, subject: "other-subject")
    api_login(user)
    get api_v1_oauth_identities_path
    expect(response.parsed_body.fetch("data")).to eq([ { "id" => row.id, "provider" => "google", "linked_at" => row.created_at.as_json } ])
    expect(response.parsed_body.fetch("meta")).to include("linking_enabled" => false, "sign_in_enabled" => false)
    expect(response.body).not_to include("synthetic-subject", "other-subject")
    expect(response.headers["Cache-Control"]).to include("no-store")
    get api_v1_oauth_identities_path, params: { user_id: other.id }
    expect(response).to have_http_status(:bad_request)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "requires CSRF and current password and rejects arbitrary claim fields" do
    row = identity
    api_login(user)
    delete api_v1_oauth_identity_path(row), params: { current_password: "password123" }, as: :json
    expect(response).to have_http_status(:forbidden)
    delete api_v1_oauth_identity_path(row), params: { current_password: "wrong" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("REAUTHENTICATION_REQUIRED")
    delete api_v1_oauth_identity_path(row), params: { current_password: "password123", subject: "forged" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(row.reload).to be_persisted
  end

  it "unlinks only owned identities and rotates all sessions and their push credentials atomically" do
    row = identity
    other = create(:user, email_address: "other@example.com")
    private_row = identity(other, subject: "other-subject")
    old_session = user.sessions.create!
    PushSubscriptionStore.register(user:, session: old_session, values: push_registration)
    api_login(user)
    old_ids = user.sessions.pluck(:id)
    delete api_v1_oauth_identity_path(private_row), params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    expect(user.sessions.pluck(:id)).to match_array(old_ids)
    delete api_v1_oauth_identity_path(row), params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(OauthIdentity.exists?(row.id)).to be(false)
    expect(OauthIdentity.exists?(private_row.id)).to be(true)
    expect(user.sessions.count).to eq(1)
    expect(user.sessions.where(id: old_ids)).not_to exist
    expect(user.push_subscriptions).not_to exist
    expect(response.parsed_body.dig("data", "csrf_token")).to be_present
    get api_v1_me_path
    expect(response).to have_http_status(:ok)
    expect(enqueued_jobs).to be_empty
  end

  it "enforces provider/subject ownership in SQL and removes identities on account deletion" do
    row = identity
    other = create(:user, email_address: "other@example.com")
    expect do
      OauthIdentity.transaction(requires_new: true) do
        OauthIdentity.insert_all!([ { user_id: other.id, provider: row.provider, subject: row.subject } ])
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
    api_login(user)
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(OauthIdentity.exists?(row.id)).to be(false)
  end

  it "rate limits password attempts without removing the identity" do
    row = identity
    api_login(user)
    10.times do
      delete api_v1_oauth_identity_path(row), params: { current_password: "wrong" }, headers: api_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
    delete api_v1_oauth_identity_path(row), params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:too_many_requests)
    expect(row.reload).to be_persisted
  end
end
