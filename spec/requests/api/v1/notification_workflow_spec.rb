# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 notification workflows" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 10, 12)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }

  def follow(key = "ACME")
    create(:follow, user:, target_key: key, skip_default_alert_rule: true)
  end

  def post_rule(target, **attributes)
    post api_v1_alert_rules_path, params: { follow_id: target.id, **attributes }, headers: api_headers, as: :json
  end

  it "creates idempotent paused digest rules and enables them only after explicit preferences" do
    target = follow
    api_login(user)
    post_rule(target)
    expect(response).to have_http_status(:created)
    id = response.parsed_body.dig("data", "id")
    expect(response.parsed_body.fetch("data")).to include("active" => false, "frequency" => "daily_digest")
    post_rule(target)
    expect(response).to have_http_status(:ok)
    expect(AlertRule.count).to eq(1)
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("error", "code")).to eq("ALERT_CONFIGURATION_REQUIRED")
    patch api_v1_notification_preferences_path, params: { time_zone: "America/New_York", email_enabled: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(AlertRule.find(id)).to be_active
    post_rule(target)
    expect(AlertRule.find(id)).to be_active
    expect(SendAlertJob).not_to have_been_enqueued
  end

  it "counts paused rules toward the three-rule Free limit and archives without erasing history" do
    targets = 4.times.map { |i| follow("KEY#{i}") }
    api_login(user)
    targets.first(3).each { |target| post_rule(target) }
    rule = targets.first.reload.alert_rule
    delivery = create(:alert_delivery, alert_rule: rule, frequency: "daily_digest")
    post_rule(targets.last)
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body).to include("feature" => "alert_rules", "limit" => 3)
    2.times do
      delete api_v1_alert_rule_path(rule), headers: api_headers, as: :json
      expect(response).to have_http_status(:no_content)
    end
    expect(AlertDelivery.exists?(delivery.id)).to be(true)
    get api_v1_alert_rules_path
    expect(response.parsed_body.fetch("data").pluck("id")).not_to include(rule.id)
    get api_v1_alert_events_path
    expect(response.parsed_body.fetch("data").pluck("id")).to include(delivery.id)
    post_rule(targets.last)
    expect(response).to have_http_status(:created)
  end

  it "rejects instant Free configurations, unsupported triggers/conditions and unowned follows" do
    target = follow
    api_login(user)
    post_rule(target, frequency: "instant")
    expect(response).to have_http_status(:payment_required)
    expect(AlertRule.count).to eq(0)
    [ { frequency: nil }, { active: "true" }, { trigger: "cluster" }, { channels: [ "push" ] }, { conditions: { min_value: 1 } } ].each do |values|
      post_rule(target, **values)
      expect(response).to have_http_status(:bad_request)
    end
    other = create(:user, email_address: "other@example.com")
    post_rule(create(:follow, user: other))
    expect(response).to have_http_status(:not_found)
    post api_v1_alert_rules_path, params: { follow_id: target.id }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "validates time zones and never infers consent on preference reads" do
    api_login(user)
    get api_v1_notification_preferences_path
    expect(response.parsed_body.fetch("data")).to include("time_zone" => nil, "email_enabled" => false, "configured" => false)
    expect(NotificationPreference.count).to eq(0)
    patch api_v1_notification_preferences_path, params: { email_enabled: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch api_v1_notification_preferences_path, params: { time_zone: "Invented/Zone", email_enabled: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch api_v1_notification_preferences_path, params: { time_zone: "Europe/London", email_enabled: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.notification_preference.email_enabled_at).to eq(Time.current)
    patch api_v1_notification_preferences_path, params: { unsubscribe_version: 0 }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
  end

  it "applies the same instant gate to the HTML resume path" do
    target = create(:follow, user:)
    target.alert_rule.setting.update!(frequency: "instant")
    consent_email(user)
    api_login(user)
    patch alert_rule_path(target.alert_rule), params: { alert_rule: { active: true } }
    expect(response).to redirect_to(alerts_path)
    expect(target.alert_rule.reload).not_to be_active
  end

  it "marks events read idempotently without treating delivery status as read state" do
    rule = create(:follow, user:).alert_rule
    delivery = create(:alert_delivery, alert_rule: rule, status: "sent")
    api_login(user)
    post api_v1_alert_event_read_path(delivery), headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    first = response.parsed_body.dig("data", "read_at")
    travel 1.minute
    post api_v1_alert_event_read_path(delivery), headers: api_headers, as: :json
    expect(response.parsed_body.dig("data", "read_at")).to eq(first)
    expect(AlertEventState.count).to eq(1)
    get api_v1_alert_events_path, params: { unread: true }
    expect(response.parsed_body.fetch("data")).to eq([])
    get api_v1_alert_events_path, params: { unread: false }
    expect(response.parsed_body.fetch("data").sole).to include("read_at" => first, "status" => "sent")
  end

  it "reads only the owned captured event set and leaves later events unread" do
    rule = create(:follow, user:).alert_rule
    3.times { create(:alert_delivery, alert_rule: rule) }
    other = create(:user, email_address: "other@example.com")
    private_event = create(:alert_delivery, alert_rule: create(:follow, user: other).alert_rule)
    api_login(user)
    post api_v1_alert_event_read_path(private_event), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    post api_v1_alert_events_read_all_path, headers: api_headers, as: :json
    expect(response.parsed_body.dig("data", "updated_count")).to eq(3)
    post api_v1_alert_events_read_all_path, headers: api_headers, as: :json
    expect(response.parsed_body.dig("data", "updated_count")).to eq(0)
    later = create(:alert_delivery, alert_rule: rule)
    get api_v1_alert_events_path, params: { unread: true }
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ later.id ])
    expect(AlertEventState.where(user_id: other.id)).not_to exist
  end

  it "preserves alert history on unfollow and restores the membership without re-enabling email" do
    target = create(:follow, user:)
    rule = enable_rule(target.alert_rule)
    delivery = create(:alert_delivery, alert_rule: rule)
    api_login(user)
    delete api_v1_watchlist_item_path(target), headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    get api_v1_watchlist_path
    expect(response.parsed_body.fetch("data")).to eq([])
    get api_v1_alert_events_path
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ delivery.id ])
    result = WatchlistMembership.add(user:, target: FollowTarget::Target.new("Ticker", target.target_key, "Example"))
    expect(result.follow.id).to eq(target.id)
    expect(rule.reload).not_to be_active
    expect(rule.setting.reload.archived_at).to be_present
  end

  it "does not admit a restored membership into an older watchlist cursor" do
    original = follow("FIRST")
    second = follow("SECOND")
    follow("THIRD")
    WatchlistMembership.remove(user:, id: original.id)
    api_login(user)
    get api_v1_watchlist_path, params: { limit: 1 }
    cursor = response.parsed_body.dig("meta", "next_cursor")
    travel 1.minute
    WatchlistMembership.add(user:, target: FollowTarget::Target.new("Ticker", "FIRST", "First"))
    get api_v1_watchlist_path, params: { limit: 1, cursor: }
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ second.id ])
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)
    get api_v1_watchlist_path
    expect(response.parsed_body.fetch("data").first.fetch("id")).to eq(original.id)
  end

  it "removes unfollowed targets from every current watchlist feed and matcher" do
    filing = create(:filing, issuer_ticker: "ACME", filed_at: 1.day.ago)
    create(:insider_transaction, filing:)
    target = create(:follow, user:)
    enable_rule(target.alert_rule)
    expect(Watchlist.new(user:).entries).not_to be_empty
    expect(FollowedActivity.new(user:).recent).not_to be_empty
    WatchlistMembership.remove(user:, id: target.id)
    expect(Watchlist.new(user:).entries).to be_empty
    expect(FollowedActivity.new(user:).recent).to be_empty
    expect { AlertEvaluator.call(filing) }.not_to change(AlertDelivery, :count)
    api_login(user)
    get api_v1_activity_path, params: { watchlist_only: true }
    expect(response.parsed_body.fetch("data")).to eq([])
    get api_v1_insider_clusters_path, params: { watchlist_only: true }
    expect(response.parsed_body.fetch("data")).to eq([])
  end

  it "deletes all private notification dependencies on account deletion without deleting filings" do
    rule = create(:follow, user:).alert_rule
    delivery = create(:alert_delivery, alert_rule: rule)
    AlertEventReads.mark(user:, id: delivery.id)
    batch = AlertDigestBatch.create!(user:, local_date: Date.current, time_zone: "UTC")
    batch.alert_digest_items.create!(alert_delivery: delivery)
    consent_email(user)
    filing_id = delivery.filing_id
    api_login(user)
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(User.exists?(user.id)).to be(false)
    [ AlertDelivery, AlertDigestBatch, AlertDigestItem, AlertEventState, AlertRuleSetting, NotificationPreference ].each { |model| expect(model.count).to eq(0) }
    expect(Filing.exists?(filing_id)).to be(true)
  end
end
