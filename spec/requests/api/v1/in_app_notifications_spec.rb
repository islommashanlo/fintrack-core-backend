# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Independent in-app filing notifications" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 11)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }
  let(:follow) { create(:follow, user:, target_key: "ACME", skip_default_alert_rule: true) }

  def rule(channel: "in_app", **attributes)
    post api_v1_alert_rules_path, params: { follow_id: follow.id, channels: [ channel ], **attributes }, headers: api_headers, as: :json
    response.parsed_body.dig("data", "id")
  end

  def configure_daily
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
  end

  def pro
    allow(Billing::Entitlements).to receive(:pro?).and_call_original
    allow(Billing::Entitlements).to receive(:pro?).with(user).and_return(true)
    allow(Billing::Entitlements).to receive(:pro_user_ids).and_return(User.where(id: user.id).select(:id))
  end

  def source(**attributes)
    create(:filing, issuer_ticker: "ACME", filed_at: Time.current, **attributes)
  end

  def notifications(**parameters)
    get api_v1_notifications_path, params: parameters
    response.parsed_body.fetch("data")
  end

  it "requires authentication and CSRF on read tracking" do
    get api_v1_notifications_path
    expect(response).to have_http_status(:unauthorized)
    api_login(user)
    post api_v1_notifications_read_all_path, as: :json
    expect(response).to have_http_status(:forbidden)
    get api_v1_notifications_path, params: { unread: "yes" }
    expect(response).to have_http_status(:bad_request)
  end

  it "activates daily in-app rules without email consent, hides pending items and publishes at local 07:00 idempotently" do
    configure_daily
    api_login(user)
    rule(active: true)
    expect(response).to have_http_status(:created)
    filing = source
    2.times { AlertEvaluator.call(filing) }
    expect(InAppNotification.count).to eq(1)
    expect(InAppNotification.sole.available_at).to eq(Time.utc(2026, 11, 12, 12))
    expect(notifications).to be_empty
    expect(AlertDelivery.count).to eq(0)
    expect(user.reload.notification_preference.email_enabled?).to be(false)
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    published = InAppNotification.sole.published_at
    PublishInAppNotificationsJob.perform_now
    expect(InAppNotification.sole.published_at).to eq(published)
    expect(notifications.sole).to include("accession" => filing.accession_no, "channel" => "in_app", "historical_filing_notice" => true)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(enqueued_jobs).to be_empty
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "requires a time zone for daily rules and gates instant delivery on Pro without requiring email settings" do
    api_login(user)
    rule(active: true)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(AlertRule.count).to eq(0)
    rule(active: true, frequency: "instant")
    expect(response).to have_http_status(:payment_required)
    pro
    rule(active: true, frequency: "instant")
    expect(response).to have_http_status(:created)
    AlertEvaluator.call(source)
    expect(notifications.size).to eq(1)
    expect(user.notification_preference).to be_nil
  end

  it "shares logical quotas across channels while refusing unsupported trigger/channel changes" do
    api_login(user)
    rule
    2.times do |i|
      target = create(:follow, user:, target_key: "OTHER#{i}", skip_default_alert_rule: true)
      AlertRuleControl.create(user:, follow_id: target.id, attributes: {})
    end
    rule(channel: "email")
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("meta", "rule_quota", "used")).to eq(3)
    expect(user.alert_rules.count).to eq(4)
    expect(AlertRuleQuota.count(user)).to eq(3)
    other = create(:follow, user:, target_key: "FOURTH", skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: other.id, channels: [ "in_app" ] }, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    rule(trigger: "news")
    expect(response).to have_http_status(:bad_request)
    id = user.alert_rules.find_by!(channel: "in_app").id
    patch api_v1_alert_rule_path(id), params: { channels: [ "email" ] }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "cancels unpublished events when rules are paused, archived, revised or their follow is removed" do
    configure_daily
    api_login(user)
    id = rule(active: true)
    AlertEvaluator.call(source)
    patch api_v1_alert_rule_path(id), params: { active: false }, headers: api_headers, as: :json
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    expect(notifications).to be_empty
    expect(InAppNotification.sole.published_at).to be_nil
    AlertRule.find(id).update!(active: true)
    AlertRule.find(id).setting.update!(revision: 2)
    PublishInAppNotificationsJob.perform_now
    expect(notifications).to be_empty
    AlertRule.find(id).setting.update!(revision: 1)
    WatchlistMembership.remove(user:, id: follow.id)
    PublishInAppNotificationsJob.perform_now
    expect(notifications).to be_empty
  end

  it "rechecks time zones and plan downgrades at publication" do
    configure_daily
    api_login(user)
    rule(active: true)
    AlertEvaluator.call(source)
    NotificationPreferences.update(user:, attributes: { time_zone: "Europe/London" })
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    expect(notifications).to be_empty
    pro
    id = user.alert_rules.sole.id
    AlertRuleControl.update(user:, id:, attributes: { active: false, frequency: "instant" })
    AlertRuleControl.update(user:, id:, active: true)
    # Model a plan downgrade between capture and publication.
    filing = source
    allow(InAppNotificationPublisher).to receive(:call).and_return(0)
    AlertEvaluator.call(filing)
    allow(InAppNotificationPublisher).to receive(:call).and_call_original
    allow(Billing::Entitlements).to receive(:pro_user_ids).and_return(User.none.select(:id))
    PublishInAppNotificationsJob.perform_now
    expect(notifications).to be_empty
  end

  it "keeps published history after unfollow and treats amendments as separate filing notices" do
    pro
    api_login(user)
    rule(active: true, frequency: "instant")
    original = source
    AlertEvaluator.call(original)
    travel 1.minute
    amendment = source(form_type: "4/A", amends_accession_no: original.accession_no)
    original.update!(superseded_by_accession_no: amendment.accession_no)
    AlertEvaluator.call(amendment)
    expect(notifications.pluck("accession")).to match_array([ original.accession_no, amendment.accession_no ])
    WatchlistMembership.remove(user:, id: follow.id)
    expect(notifications.size).to eq(2)
    original.update!(parse_status: "failed")
    expect(notifications.pluck("accession")).to eq([ amendment.accession_no ])
  end

  it "isolates accounts, marks read idempotently and leaves later arrivals unread" do
    pro
    api_login(user)
    rule(active: true, frequency: "instant")
    AlertEvaluator.call(source)
    row = InAppNotification.sole
    other = create(:user, email_address: "other@example.com")
    private_rule = create(:follow, user: other).alert_rule
    private_row = InAppNotification.create!(alert_rule: private_rule, filing: row.filing, rule_revision: 1, frequency: "instant", available_at: Time.current, published_at: Time.current)
    post api_v1_notification_read_path(private_row), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    post api_v1_notification_read_path(row), headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    first = row.reload.read_at
    travel 1.minute
    post api_v1_notification_read_path(row), headers: api_headers, as: :json
    expect(row.reload.read_at).to eq(first)
    expect(notifications(unread: true)).to be_empty
    AlertEvaluator.call(source)
    post api_v1_notifications_read_all_path, headers: api_headers, as: :json
    expect(response.parsed_body.dig("data", "updated_count")).to eq(1)
    AlertEvaluator.call(source)
    expect(notifications(unread: true).size).to eq(1)
    get api_v1_notifications_summary_path
    expect(response.parsed_body.fetch("data")).to include("total_count" => 3, "read_count" => 2, "unread_count" => 1)
    expect(private_row.reload.read_at).to be_nil
  end

  it "leaves older pending rows unread when they publish after read-all" do
    pro
    api_login(user)
    rule(active: true, frequency: "instant")
    allow(InAppNotificationPublisher).to receive(:call).and_return(0)
    AlertEvaluator.call(source)
    pending = InAppNotification.sole
    allow(InAppNotificationPublisher).to receive(:call).and_call_original
    AlertEvaluator.call(source)
    # Ingest publication is filing-scoped: the older pending ID stays hidden.
    post api_v1_notifications_read_all_path, headers: api_headers, as: :json
    expect(response.parsed_body.dig("data", "updated_count")).to eq(1)
    expect(pending.reload.read_at).to be_nil
    PublishInAppNotificationsJob.perform_now
    expect(notifications(unread: true).pluck("id")).to eq([ pending.id ])
  end

  it "pins cursor membership and rejects another account's cursor" do
    pro
    api_login(user)
    rule(active: true, frequency: "instant")
    2.times { AlertEvaluator.call(source) }
    notifications(limit: 1)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    AlertEvaluator.call(source)
    expect(notifications(limit: 1, cursor:).size).to eq(1)
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)
    other = create(:user, email_address: "other@example.com", password: "password123")
    api_login(other)
    get api_v1_notifications_path, params: { limit: 1, cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "uses the next local cutoff across daylight saving changes and after 07:00" do
    travel_to(Time.utc(2026, 3, 8, 10))
    configure_daily
    api_login(user)
    rule(active: true)
    AlertEvaluator.call(source)
    expect(InAppNotification.sole.available_at).to eq(Time.utc(2026, 3, 8, 11))
    travel 1.hour
    AlertEvaluator.call(source)
    expect(InAppNotification.order(:id).last.available_at).to eq(Time.utc(2026, 3, 9, 11))
  end

  it "matches institutional filing notices and bounds each publication batch" do
    configure_daily
    api_login(user)
    target = create(:follow, user:, target_type: "InstitutionalFiler", target_key: "0000000123", skip_default_alert_rule: true)
    AlertRuleControl.create(user:, follow_id: target.id, attributes: { channel: "in_app", active: true })
    3.times { AlertEvaluator.call(source(form_type: "13F-NT")) }
    expect(InAppNotification.count).to eq(3)
    stub_const("InAppNotificationPublisher::BATCH_SIZE", 2)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(2)
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(notifications.size).to eq(3)
    get api_v1_alert_events_path
    expect(response.parsed_body.fetch("data")).to be_empty
  end

  it "does not match filings accepted before activation and cleans notifications on account deletion" do
    pro
    api_login(user)
    rule(active: true, frequency: "instant")
    AlertEvaluator.call(source(filed_at: 1.day.ago))
    expect(InAppNotification.count).to eq(0)
    AlertEvaluator.call(source)
    expect(InAppNotification.count).to eq(1)
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(InAppNotification.count).to eq(0)
    expect(Filing.count).to eq(2)
  end
end
