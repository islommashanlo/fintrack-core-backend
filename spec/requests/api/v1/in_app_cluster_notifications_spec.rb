# frozen_string_literal: true

require "rails_helper"

RSpec.describe "In-app insider cluster notifications" do
  include ApiAccounts
  include ClusterAlertHelpers
  around { |example| travel_to(Time.utc(2026, 11, 12, 11)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }

  def pro
    allow(Billing::Entitlements).to receive(:pro?).and_call_original
    allow(Billing::Entitlements).to receive(:pro?).with(user).and_return(true)
    allow(Billing::Entitlements).to receive(:pro_user_ids).and_return(User.where(id: user.id).select(:id))
  end

  def in_app_rule(type: "Ticker", key: "ACME", conditions: {}, frequency: "daily_digest")
    target = create(:follow, user:, target_type: type, target_key: key, followed_at: 1.year.ago, skip_default_alert_rule: true)
    result = AlertRuleControl.create(user:, follow_id: target.id,
      attributes: { channel: "in_app", event_type: "cluster", active: true, frequency:,
        conditions: ClusterAlertConditions.normalize(conditions) }).rule
    result.setting.update!(enabled_at: 1.year.ago)
    result
  end

  def list(**parameters)
    get api_v1_notifications_path, params: parameters
    response.parsed_body.fetch("data")
  end

  it "creates typed cluster rules via API without email consent and preserves Free/Pro timing gates" do
    api_login(user)
    follow = create(:follow, user:, target_key: "ACME", skip_default_alert_rule: true)
    values = { follow_id: follow.id, channels: [ "in_app" ], trigger: "cluster", active: true, frequency: "instant",
      conditions: { direction: "purchase", min_insiders: 3, min_value: "500" } }
    post api_v1_alert_rules_path, params: values, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    pro
    post api_v1_alert_rules_path, params: values, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("meta", "in_app_supported_triggers")).to include("cluster")
    trades = 3.times.map { |i| cluster_trade(cik: format("%010d", 901 + i), at: Time.current) }
    AlertEvaluator.call(trades.last.filing)
    data = list.sole
    expect(data).to include("trigger" => "cluster", "channel" => "in_app", "accession" => trades.last.accession_no)
    expect(data.fetch("cluster")).to include("insider_count" => 3, "transaction_count" => 3, "total_value" => "600.0")
    expect(data.fetch("cluster").fetch("sources").pluck("accession")).to match_array(trades.map(&:accession_no))
    expect(data.fetch("transaction")).to be_nil
    expect(user.notification_preference).to be_nil
    expect(AlertDelivery.count).to eq(0)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "shares immutable snapshots across channels and deduplicates evaluation and repeated cluster sources" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    target = in_app_rule
    consent_email(user)
    email = AlertRuleControl.create(user:, follow_id: target.follow_id, attributes: { event_type: "cluster", active: true }).rule
    email.setting.update!(enabled_at: 1.year.ago)
    trades = cluster_trades
    2.times { AlertEvaluator.call(trades.last.filing) }
    expect(InAppNotification.count).to eq(1)
    expect(AlertDelivery.count).to eq(1)
    snapshot = InsiderClusterSnapshot.sole
    expect(InAppNotification.sole.insider_cluster_snapshot_id).to eq(AlertDelivery.sole.insider_cluster_snapshot_id)
    expect(AlertRuleQuota.count(user)).to eq(1)
    expect { snapshot.update!(insider_count: 999) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    row = InAppNotification.sole
    expect do
      InAppNotification.transaction(requires_new: true) { InAppNotification.insert_all!([ row.attributes.except("id") ]) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "does not inflate participants using joint owners and matches a followed joint owner through the canonical line" do
    pro
    api_login(user)
    rule = in_app_rule(type: "Insider", key: "0000000999", frequency: "instant")
    trades = cluster_trades
    create(:insider_transaction, filing: trades.first.filing, insider_cik: "0000000999", owner_seq: 2, txn_seq: trades.first.txn_seq)
    AlertEvaluator.call(trades.last.filing)
    expect(rule.in_app_notifications.sole.insider_cluster_snapshot).to have_attributes(insider_count: 3, transaction_count: 3)
    expect(list.sole.fetch("entity")).to include("type" => "person", "key" => "0000000999")
  end

  it "matches sale direction and thresholds while keeping incomplete values unknown" do
    pro
    api_login(user)
    target = in_app_rule(conditions: { "direction" => "sale", "min_insiders" => 3, "min_value" => "500" }, frequency: "instant")
    purchases = cluster_trades
    AlertEvaluator.call(purchases.last.filing)
    expect(InAppNotification.count).to eq(0)
    sales = cluster_trades(code: "S")
    sales.first.update!(price: nil)
    AlertEvaluator.call(sales.last.filing)
    expect(InAppNotification.count).to eq(0)
    AlertRuleControl.update(user:, id: target.id, attributes: { active: false, conditions: { "direction" => "sale" } })
    AlertRuleControl.update(user:, id: target.id, active: true)
    # New accepted sources after the revised activation window can match.
    later = cluster_trade(cik: "0000000904", at: Time.current, code: "S")
    AlertEvaluator.call(later.filing)
    cluster = list.sole.fetch("cluster")
    expect(cluster).to include("direction" => "sale", "insider_count" => 4, "total_value" => nil, "known_value_subtotal" => "600.0")
    expect(cluster.fetch("transactions_without_usable_price")).to eq(1)
  end

  it "discovers delayed membership with the window's primary filing and publishes the correct source immediately" do
    pro
    api_login(user)
    rule = in_app_rule(frequency: "instant")
    latest = cluster_trade(cik: "0000000903", at: 1.hour.ago)
    cluster_trade(cik: "0000000902", at: 2.hours.ago)
    AlertEvaluator.call(latest.filing)
    expect(InAppNotification.count).to eq(0)
    delayed = cluster_trade(cik: "0000000901", at: 3.hours.ago)
    AlertEvaluator.call(delayed.filing)
    row = rule.in_app_notifications.sole
    expect(row.filing_id).to eq(latest.filing_id)
    expect(row.published_at).to eq(Time.current)
    expect(list.sole.fetch("accession")).to eq(latest.accession_no)
  end

  it "keeps separate immutable rolling-window states when late membership changes" do
    pro
    api_login(user)
    rule = in_app_rule(frequency: "instant")
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    old = InsiderClusterSnapshot.sole
    late = cluster_trade(cik: "0000000904", at: 2.hours.ago + 1.minute)
    AlertEvaluator.call(late.filing)
    current = cluster_trade(cik: "0000000905", at: 1.minute.ago)
    AlertEvaluator.call(current.filing)
    expect(rule.in_app_notifications.count).to eq(4)
    expect(old.reload.transaction_ids).to eq(trades.map(&:id))
    expect(InsiderClusterSnapshot.where(window_end: trades.last.filing.filed_at).count).to eq(2)
  end

  it "suppresses queued clusters when any constituent is superseded even if the primary filing is unchanged" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    rule = in_app_rule
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    create(:filing, form_type: "4/A", filed_at: 1.minute.ago, amends_accession_no: trades.first.accession_no)
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    expect(rule.in_app_notifications.sole.published_at).to be_nil
    expect(list).to be_empty
  end

  it "hides invalid published clusters from summary and read state while retaining their snapshots" do
    pro
    api_login(user)
    in_app_rule(frequency: "instant")
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    row = InAppNotification.sole
    trades.first.filing.update!(parse_status: "failed")
    expect(list).to be_empty
    get api_v1_notifications_summary_path
    expect(response.parsed_body.dig("data", "total_count")).to eq(0)
    post api_v1_notification_read_path(row), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    post api_v1_notifications_read_all_path, headers: api_headers, as: :json
    expect(response.parsed_body.dig("data", "updated_count")).to eq(0)
    expect(row.reload.read_at).to be_nil
    expect(InsiderClusterSnapshot.count).to eq(1)
  end

  it "uses local digest timing without email consent and preserves paused/removed-source policy" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    target = in_app_rule
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    expect(list).to be_empty
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    expect(list.size).to eq(1)
    WatchlistMembership.remove(user:, id: target.follow_id)
    expect(list.size).to eq(1)
    expect(user.reload.notification_preference.email_enabled?).to be(false)
  end

  it "rejects fund rules, bad conditions and inconsistent source shapes" do
    pro
    api_login(user)
    fund = create(:follow, user:, target_type: "InstitutionalFiler", target_key: "0000000123", skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: fund.id, trigger: "cluster", channels: [ "in_app" ] }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    issuer = create(:follow, user:, target_key: "ACME", skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: issuer.id, trigger: "cluster", channels: [ "in_app" ], conditions: { min_insiders: 2 } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    target = AlertRuleControl.create(user:, follow_id: issuer.id, attributes: { event_type: "cluster", channel: "in_app", active: true, frequency: "instant" }).rule
    target.setting.update!(enabled_at: 1.year.ago)
    issuer.update!(followed_at: 1.year.ago)
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    row = InAppNotification.sole
    wrong = create(:filing)
    row.filing = wrong
    expect(row).not_to be_valid
    row.reload.update_column(:filing_id, wrong.id)
    expect(list).to be_empty
    expect do
      InAppNotification.transaction(requires_new: true) { row.update_columns(event_type: "new_filing") }
    end.to raise_error(ActiveRecord::StatementInvalid, /in_app_notification_source/)
  end
end
