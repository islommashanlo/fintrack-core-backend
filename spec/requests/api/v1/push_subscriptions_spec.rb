# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 push subscription lifecycle" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }

  def data = response.parsed_body.fetch("data")

  def register(values = push_registration)
    post api_v1_push_subscriptions_path, params: values, headers: api_headers, as: :json
  end

  it "requires authentication and browser CSRF on registration and revocation" do
    get api_v1_push_subscriptions_path
    expect(response).to have_http_status(:unauthorized)
    api_login(user)
    post api_v1_push_subscriptions_path, params: push_registration, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(PushSubscription.count).to eq(0)
    register
    id = data.fetch("id")
    delete api_v1_push_subscription_path(id), as: :json
    expect(response).to have_http_status(:forbidden)
    expect(PushSubscription.count).to eq(1)
  end

  it "registers idempotently, encrypts credentials and returns metadata only without enabling delivery or email" do
    api_login(user)
    values = push_registration
    register(values)
    expect(response).to have_http_status(:created)
    first = data
    row = PushSubscription.sole
    encrypted = row.encrypted_payload
    expect(PushSubscriptionSecrets.decrypt(row)).to eq(values.fetch("subscription"))
    expect(encrypted).not_to include(values.dig("subscription", "endpoint"), values.dig("subscription", "keys", "auth"), values.dig("subscription", "keys", "p256dh"))
    expect(data).to include("endpoint_origin" => "https://push.example.invalid", "active" => true, "current_session" => true)
    expect(response.body).not_to include("private-capability-token", '"keys"', '"auth"', '"encrypted_payload"', row.endpoint_digest)
    expect(response.parsed_body.fetch("meta")).to include("delivery_enabled" => false, "maximum_subscriptions" => 20)
    travel 1.minute
    register(values)
    expect(response).to have_http_status(:ok)
    expect(data).to eq(first)
    expect(row.reload.encrypted_payload).to eq(encrypted)
    expect(user.notification_preference).to be_nil
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rotates keys and expiry only for the authenticated owner while preserving identity" do
    api_login(user)
    register
    row = PushSubscription.sole
    old = row.encrypted_payload
    values = push_registration(expiration: 1.day.from_now.to_i * 1000)
    values["subscription"]["keys"]["auth"] = Base64.urlsafe_encode64("fedcba9876543210", padding: false)
    travel 1.minute
    register(values)
    expect(response).to have_http_status(:ok)
    expect(PushSubscription.count).to eq(1)
    expect(row.reload.encrypted_payload).not_to eq(old)
    expect(PushSubscriptionSecrets.decrypt(row)).to eq(values.fetch("subscription"))
    expect(row.consented_at).to eq(Time.current)
  end

  it "isolates listings and revocation and never silently transfers another account's endpoint" do
    other = create(:user, email_address: "other@example.com")
    other_session = other.sessions.create!
    other_row = PushSubscriptionStore.register(user: other, session: other_session, values: push_registration).record
    api_login(user)
    register(push_registration(endpoint: "https://Push.Example.Invalid:443/messages/private-capability-token-0001"))
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("PUSH_SUBSCRIPTION_CONFLICT")
    expect(other_row.reload.user_id).to eq(other.id)
    get api_v1_push_subscriptions_path
    expect(data).to be_empty
    delete api_v1_push_subscription_path(other_row.id), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    expect(PushSubscription.count).to eq(1)
  end

  it "lists bounded metadata with account/session-bound cursors and current expiration status" do
    api_login(user)
    2.times { |i| register(push_registration(endpoint: "https://push.example.invalid/messages/device-#{i}", expiration: 1.hour.from_now.to_i * 1000)) }
    get api_v1_push_subscriptions_path, params: { limit: 1 }
    expect(data.size).to eq(1)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    cursor = response.parsed_body.dig("meta", "next_cursor")
    travel 2.hours
    get api_v1_push_subscriptions_path, params: { cursor:, limit: 100 }
    expect(data.size).to eq(1)
    expect(data.sole.fetch("active")).to be(true) # Status uses the signed snapshot time.
    get api_v1_push_subscriptions_path
    expect(data.pluck("active")).to eq([ false, false ])
    api_login(create(:user, email_address: "reader@example.com", password: "password123"))
    get api_v1_push_subscriptions_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "enforces a bounded device count while permitting refreshes and explicit revocation" do
    api_login(user)
    stub_const("PushSubscriptionStore::MAXIMUM", 2)
    register
    first_id = data.fetch("id")
    register(push_registration(endpoint: "https://push.example.invalid/messages/device-2"))
    register(push_registration(endpoint: "https://push.example.invalid/messages/device-3"))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("error", "code")).to eq("PUSH_SUBSCRIPTION_LIMIT")
    register
    expect(response).to have_http_status(:ok)
    delete api_v1_push_subscription_path(first_id), headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    register(push_registration(endpoint: "https://push.example.invalid/messages/device-3"))
    expect(response).to have_http_status(:created)
  end

  it "removes endpoint secrets on logout, credential rotation and password-authenticated account deletion" do
    api_login(user)
    register
    delete api_v1_auth_logout_path, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(PushSubscription.count).to eq(0)
    api_login(user)
    register
    patch api_v1_me_path, params: { current_password: "password123", password: "changedpassword123", password_confirmation: "changedpassword123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(PushSubscription.count).to eq(0)
    @api_csrf = response.parsed_body.fetch("data").fetch("csrf_token")
    register
    delete api_v1_me_path, params: { current_password: "changedpassword123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(PushSubscription.count).to eq(0)
  end

  it "fails closed on corrupt ciphertext while keeping metadata and revoke available" do
    api_login(user)
    register
    row = PushSubscription.sole
    row.update_column(:encrypted_payload, "corrupted")
    register
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include("corrupted", "private-capability-token")
    get api_v1_push_subscriptions_path
    expect(data.pluck("id")).to eq([ row.id ])
    delete api_v1_push_subscription_path(row.id), headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
  end

  it "rejects unknown fields and malformed IDs/list filters without exposing credentials" do
    api_login(user)
    register(push_registration.merge("session_id" => 1))
    expect(response).to have_http_status(:bad_request)
    get api_v1_push_subscriptions_path, params: { limit: 101 }
    expect(response).to have_http_status(:bad_request)
    delete api_v1_push_subscription_path("bad"), headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(push_registration)
    expect(filtered.fetch("subscription")).to eq("[FILTERED]")
  end
end
