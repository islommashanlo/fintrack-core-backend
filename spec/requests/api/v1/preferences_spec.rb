# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 account preferences" do
  include ApiAccounts
  around { |example| with_api_csrf_protection { example.run } }

  let(:user) { create(:user, password: "password123") }

  it "returns defaults without creating records or enabling email" do
    api_login(user)
    session_id = user.sessions.sole.id
    expect do
      get api_v1_preferences_path
    end.not_to change(UserPreference, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("data" => { "theme" => "system", "dashboard_layout" => "split" })
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(user.reload.notification_preference).to be_nil
    expect(user.sessions.sole.id).to eq(session_id)
  end

  it "persists partial changes and returns only the current user's two display preferences" do
    other = create(:user, email_address: "other@example.com", password: "password123")
    other_preference = other.create_user_preference!(theme: "light", dashboard_layout: "focus")
    api_login(user)
    token = user.password_reset_token
    session_id = user.sessions.sole.id
    expect do
      patch api_v1_preferences_path, params: { theme: "dark" }, headers: api_headers, as: :json
    end.to change(UserPreference, :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("data" => { "theme" => "dark", "dashboard_layout" => "split" })
    id = user.reload.user_preference.id
    patch api_v1_preferences_path, params: { dashboard_layout: "columns" }, headers: api_headers, as: :json
    expect(response.parsed_body).to eq("data" => { "theme" => "dark", "dashboard_layout" => "columns" })
    patch api_v1_preferences_path, params: { dashboard_layout: "columns" }, headers: api_headers, as: :json
    expect(user.reload.user_preference.id).to eq(id)
    expect(user.sessions.sole.id).to eq(session_id)
    expect(User.find_by_password_reset_token(token)).to eq(user)
    expect(other_preference.reload).to have_attributes(theme: "light", dashboard_layout: "focus")
    get api_v1_preferences_path
    expect(response.parsed_body.dig("data", "theme")).to eq("dark")
  end

  it "accepts each documented theme and dashboard layout" do
    api_login(user)
    %w[system light dark].each do |theme|
      patch api_v1_preferences_path, params: { theme: }, headers: api_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "theme")).to eq(theme)
    end
    %w[split focus columns].each do |dashboard_layout|
      patch api_v1_preferences_path, params: { dashboard_layout: }, headers: api_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "dashboard_layout")).to eq(dashboard_layout)
    end
  end

  it "requires authentication and protects mutations with CSRF and origin checks" do
    get api_v1_preferences_path
    expect(response).to have_http_status(:unauthorized)
    api_csrf
    patch api_v1_preferences_path, params: { theme: "dark" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    api_login(user)
    patch api_v1_preferences_path, params: { theme: "dark" }, as: :json
    expect(response).to have_http_status(:forbidden)
    patch api_v1_preferences_path, params: { theme: "dark" }, headers: api_headers.merge("Origin" => "https://untrusted.example"), as: :json
    expect(response).to have_http_status(:forbidden)
    expect(UserPreference.count).to eq(0)
  end

  it "rejects unknown fields, empty bodies and non-string values without saving anything" do
    api_login(user)
    [ {}, { theme: nil }, { theme: "" }, { theme: [] }, { dashboard_layout: {} }, { theme: false },
      { theme: "dark", user_id: 1 }, { plan: "pro" }, { email_enabled: true } ].each do |values|
      expect do
        patch api_v1_preferences_path, params: values, headers: api_headers, as: :json
      end.not_to change(UserPreference, :count)
      expect(response).to have_http_status(:bad_request)
    end
    get api_v1_preferences_path, params: { user_id: user.id }
    expect(response).to have_http_status(:bad_request)
    expect(user.reload.notification_preference).to be_nil
  end

  it "rejects unsupported enums atomically, preserving existing values" do
    api_login(user)
    user.create_user_preference!(theme: "light", dashboard_layout: "split")
    patch api_v1_preferences_path, params: { theme: "dark", dashboard_layout: "invalid" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("error", "code")).to eq("VALIDATION_FAILED")
    expect(response.parsed_body.dig("error", "details")).to include("dashboard_layout")
    expect(user.reload.user_preference).to have_attributes(theme: "light", dashboard_layout: "split")
    patch api_v1_preferences_path, params: { theme: "LIGHT" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(user.reload.user_preference.theme).to eq("light")
  end

  it "removes only the deleted account's preference record" do
    other = create(:user, email_address: "other@example.com", password: "password123")
    other_preference = other.create_user_preference!(theme: "dark")
    api_login(user)
    own = user.create_user_preference!(theme: "light")
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(UserPreference.exists?(own.id)).to be(false)
    expect(UserPreference.exists?(other_preference.id)).to be(true)
  end
end
