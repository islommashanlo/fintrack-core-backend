# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 push notification preferences" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }

  def data = response.parsed_body.fetch("data")

  def update_preferences(values)
    patch api_v1_notification_preferences_path, params: values, headers: api_headers, as: :json
  end

  it "defaults to disabled without persisting consent and protects browser mutations" do
    get api_v1_notification_preferences_path
    expect(response).to have_http_status(:unauthorized)
    api_login(user)
    get api_v1_notification_preferences_path
    expect(data).to include("push_enabled" => false)
    expect(data.fetch("push")).to include("eligible" => false, "delivery_enabled" => false,
      "blockers" => %w[consent_required device_required pro_required delivery_disabled])
    expect(NotificationPreference.count).to eq(0)
    patch api_v1_notification_preferences_path, params: { push_enabled: true }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(NotificationPreference.count).to eq(0)
  end

  it "records separate consent, preserves email unsubscribe tokens and refreshes the consent window only on reactivation" do
    api_login(user)
    update_preferences(time_zone: "Europe/London", email_enabled: true)
    original = user.reload.notification_preference
    version, email_time = original.unsubscribe_version, original.email_enabled_at
    travel 1.minute
    update_preferences(push_enabled: true)
    expect(response).to have_http_status(:ok)
    expect(data).to include("push_enabled" => true, "email_enabled" => true)
    preference = original.reload
    first_consent = preference.push_enabled_at
    expect(first_consent).to eq(Time.current)
    travel 1.minute
    update_preferences(push_enabled: true)
    expect(preference.reload.push_enabled_at).to eq(first_consent)
    update_preferences(push_enabled: false)
    expect(data.dig("push", "blockers")).to include("consent_required")
    travel 1.minute
    update_preferences(push_enabled: true)
    expect(preference.reload.push_enabled_at).to eq(Time.current)
    expect(preference.unsubscribe_version).to eq(version)
    expect(preference.email_enabled_at).to eq(email_time)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects coercion and server-owned fields without changing existing consent" do
    api_login(user)
    update_preferences(push_enabled: true)
    [ { push_enabled: "true" }, { push_enabled: 1 }, { push_enabled: nil }, { push_enabled_at: Time.current.iso8601 }, { push: { eligible: true } } ].each do |values|
      update_preferences(values)
      expect(response).to have_http_status(:bad_request)
      expect(user.reload.notification_preference).to be_push_enabled
    end
    expect(user.notification_preference.email_enabled?).to be(false)
  end

  it "requires a current-session device and current plan while transport and rule creation stay disabled" do
    api_login(user)
    update_preferences(push_enabled: true)
    other_session = user.sessions.create!
    PushSubscriptionStore.register(user:, session: other_session, values: push_registration)
    get api_v1_notification_preferences_path
    expect(data.dig("push", "current_session_device")).to be(false)
    post api_v1_push_subscriptions_path, params: push_registration, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    allow(Billing::Entitlements).to receive(:pro?).with(user).and_return(true)
    get api_v1_notification_preferences_path
    expect(data.fetch("push")).to include("consent_enabled" => true, "current_session_device" => true,
      "plan_eligible" => true, "eligible" => false, "blockers" => [ "delivery_disabled" ])
    allow(Billing::Entitlements).to receive(:pro?).with(user).and_return(false)
    get api_v1_notification_preferences_path
    expect(data.dig("push", "blockers")).to include("pro_required")
    target = create(:follow, user:, skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: target.id, channels: [ "push" ] }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    travel 31.days
    expect(PushChannelEligibility.call(user:, session: other_session)[:current_session_device]).to be(false)
  end

  it "isolates accounts and treats expired device registrations as unavailable" do
    other = create(:user, email_address: "other@example.com")
    NotificationPreferences.update(user: other, attributes: { push_enabled: true })
    api_login(user)
    post api_v1_push_subscriptions_path, params: push_registration(expiration: 1.minute.from_now.to_i * 1000), headers: api_headers, as: :json
    update_preferences(push_enabled: true)
    expect(data.dig("push", "current_session_device")).to be(true)
    travel 1.minute
    get api_v1_notification_preferences_path
    expect(data.dig("push", "current_session_device")).to be(false)
    update_preferences(push_enabled: false)
    expect(other.reload.notification_preference).to be_push_enabled
    expect(PushSubscription.count).to eq(1)
  end
end
