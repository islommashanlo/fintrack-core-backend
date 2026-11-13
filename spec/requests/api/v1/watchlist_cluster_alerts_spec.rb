# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Watchlist cluster alerts" do
  include ApiAccounts
  include OpenapiResponses
  include ClusterAlertHelpers
  around { |example| travel_to(Time.utc(2026, 11, 13, 11)) { example.run } }
  let(:user) { create(:user, password: "password123") }

  def member(type: "Ticker", key: "ACME")
    create(:follow, user:, target_type: type, target_key: key, followed_at: 1.year.ago, skip_default_alert_rule: true)
  end

  def activate(channel:, conditions: {}, frequency: "daily_digest")
    channel == "email" ? consent_email(user) : NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    post api_v1_alert_rules_path, params: { scope: "watchlist", trigger: "cluster", channels: [ channel ],
      active: true, frequency:, conditions: }, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    expect_documented_response(path: "/alert-rules", method: :post)
    expect(response.parsed_body.dig("meta", "watchlist_#{channel}_supported_triggers")).to include("cluster")
    rule = AlertRule.find(response.parsed_body.dig("data", "id"))
    rule.setting.update!(enabled_at: 1.year.ago)
    rule
  end

  def both(**options)
    %w[email in_app].map { |channel| activate(channel:, **options) }
  end

  def notices
    get api_v1_notifications_path
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/notifications", method: :get)
    response.parsed_body.fetch("data")
  end

  it "deduplicates overlapping issuer and joint-owner matches, shares snapshots and delivers factual digests" do
    issuer = member
    person = member(type: "Insider", key: "0000000999")
    both
    trades = cluster_trades
    create(:insider_transaction, filing: trades.first.filing, insider_cik: person.target_key,
      owner_seq: 2, txn_seq: trades.first.txn_seq)
    2.times { AlertEvaluator.call(trades.last.filing) }
    expect(AlertDelivery.count).to eq(1)
    expect(InAppNotification.count).to eq(1)
    snapshot = InsiderClusterSnapshot.sole
    expect(snapshot).to have_attributes(insider_count: 3, transaction_count: 3, transaction_ids: trades.map(&:id))
    expect(AlertDelivery.sole.insider_cluster_snapshot_id).to eq(InAppNotification.sole.insider_cluster_snapshot_id)
    expect(WatchlistFilingMembership.where(alert_delivery_id: AlertDelivery.sole.id).pluck(:follow_id)).to match_array([ issuer.id, person.id ])
    expect(WatchlistFilingMembership.count).to eq(4)
    expect(AlertRuleQuota.count(user)).to eq(1)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    row = notices.sole
    expect(row.fetch("entity")).to include("type" => "watchlist", "key" => nil)
    expect(row.fetch("matched_entities").pluck("follow_id")).to match_array([ issuer.id, person.id ])
    expect(row.dig("cluster", "sources").pluck("accession")).to match_array(trades.map(&:accession_no))
    batch = AlertDigestPlanner.call(user:)
    SendAlertDigestJob.perform_now(batch.id)
    expect(ActionMailer::Base.deliveries.last.text_part.body.decoded).to include("3 first-listed insiders", "Issuer ACME", "Person 0000000999", *trades.map { |t| t.filing.sec_url })
    get api_v1_alert_events_path, params: { scope: "watchlist" }
    expect_documented_response(path: "/alert-events", method: :get)
    expect(response.parsed_body.fetch("data").sole.fetch("matched_entities_total_count")).to eq(2)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "keeps a pending cluster eligible when another captured membership remains current" do
    issuer = member
    member(type: "Insider", key: "0000000901")
    both
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    WatchlistMembership.remove(user:, id: issuer.id)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(notices.sole.fetch("matched_entities_total_count")).to eq(2)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest").count).to eq(1)
  end

  it "does not append new follows or re-added epochs to first-capture evidence" do
    issuer = member
    both
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    evidence = WatchlistFilingMembership.order(:id).map(&:attributes)
    WatchlistMembership.remove(user:, id: issuer.id)
    travel 1.second
    WatchlistMembership.add(user:, target: FollowTarget::Target.new("Ticker", "ACME", "Example"))
    member(type: "Insider", key: "0000000901")
    AlertEvaluator.call(trades.last.filing)
    expect(AlertDelivery.count).to eq(1)
    expect(InAppNotification.count).to eq(1)
    expect(WatchlistFilingMembership.order(:id).map(&:attributes)).to eq(evidence)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(notices).to be_empty
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
  end

  it "isolates witnesses for different windows so another live source cannot release a removed match" do
    first_member = member(type: "Insider", key: "0000000901")
    second_member = member(type: "Insider", key: "0000000904")
    both
    first = cluster_trades
    second = 3.times.map do |i|
      cluster_trade(cik: format("%010d", 904 + i), issuer: "0000000999", at: (3 - i).hours.ago)
    end
    AlertEvaluator.call(first.last.filing)
    AlertEvaluator.call(second.last.filing)
    WatchlistMembership.remove(user:, id: first_member.id)
    expect(WatchlistFilingMembership.count).to eq(4)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(notices.sole.fetch("matched_entities").sole.fetch("follow_id")).to eq(second_member.id)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest").pluck(:filing_id)).to eq([ second.last.filing_id ])
  end

  it "suppresses both channels when any constituent is amended while preserving stored evidence" do
    member
    both
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    snapshot = InsiderClusterSnapshot.sole
    create(:filing, form_type: "4/A", issuer_ticker: "ACME", filed_at: Time.current,
      amends_accession_no: trades.first.accession_no)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
    expect(snapshot.reload.transaction_ids).to eq(trades.map(&:id))
    expect(AlertDelivery.count).to eq(1)
    expect(InAppNotification.count).to eq(1)
  end

  it "rechecks canonical participant validity in both channels" do
    member
    both
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    trades.first.update!(owner_seq: 2)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
  end

  it "discovers delayed constituents and uses the later primary filing for instant delivery and publication" do
    with_billing_config do
      bind_billing_customer(user)
      apply_billing_event
      member
      both(frequency: "instant")
      latest = cluster_trade(cik: "0000000903", at: 1.hour.ago)
      cluster_trade(cik: "0000000902", at: 2.hours.ago)
      AlertEvaluator.call(latest.filing)
      expect(InAppNotification.count).to eq(0)
      delayed = cluster_trade(cik: "0000000901", at: 3.hours.ago)
      AlertEvaluator.call(delayed.filing)
      delivery = AlertDelivery.sole
      expect(delivery.filing_id).to eq(latest.filing_id)
      expect(InAppNotification.sole.published_at).to eq(Time.current)
      expect(notices.sole.fetch("accession")).to eq(latest.accession_no)
      expect(WatchlistFilingMembership.pluck(:filing_id).uniq).to eq([ latest.filing_id ])
      expect(SendAlertJob).to have_been_enqueued.with(delivery.id)
      2.times { SendAlertJob.perform_now(delivery.id) }
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(ActionMailer::Base.deliveries.last.subject).to eq("Reported insider cluster for your watchlist")
    end
  end

  it "applies direction and complete-value thresholds without treating missing prices as zero" do
    member
    both(conditions: { direction: "sale", min_value: "0", min_insiders: 3 })
    purchases = cluster_trades
    AlertEvaluator.call(purchases.last.filing)
    expect(AlertDelivery.count).to eq(0)
    sales = cluster_trades(code: "S")
    sales.first.update!(price: nil)
    AlertEvaluator.call(sales.last.filing)
    expect(AlertDelivery.count).to eq(0)
    expect(InAppNotification.count).to eq(0)
  end

  it "rejects pre-activation, future, failed and fund-only matches" do
    member
    rules = both
    rules.each { |rule| rule.setting.update!(enabled_at: Time.current) }
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    expect(AlertDelivery.count).to eq(0)
    future = cluster_trade(cik: "0000000904", at: 1.hour.from_now)
    AlertEvaluator.call(future.filing)
    failed = cluster_trade(cik: "0000000905", at: Time.current)
    failed.filing.update!(parse_status: "failed")
    AlertEvaluator.call(failed.filing)
    expect(InAppNotification.count).to eq(0)
    user.follows.current.each { |follow| WatchlistMembership.remove(user:, id: follow.id) }
    fund = create(:institutional_filer)
    member(type: "InstitutionalFiler", key: fund.cik)
    fresh = cluster_trade(cik: "0000000906", at: Time.current)
    AlertEvaluator.call(fresh.filing)
    expect(WatchlistFilingMembership.count).to eq(0)
  end

  it "caps displayed evidence while retaining every matching membership" do
    member
    20.times { |i| member(type: "Insider", key: format("%010d", 2000 + i)) }
    both
    trades = cluster_trades
    20.times do |i|
      create(:insider_transaction, filing: trades.first.filing, insider_cik: format("%010d", 2000 + i),
        owner_seq: i + 2, txn_seq: trades.first.txn_seq)
    end
    AlertEvaluator.call(trades.last.filing)
    expect(WatchlistFilingMembership.count).to eq(42)
    expect(InsiderClusterSnapshot.sole.insider_count).to eq(3)
    travel 1.hour
    InAppNotificationPublisher.call
    row = notices.sole
    expect(row.fetch("matched_entities").length).to eq(20)
    expect(row).to include("matched_entities_total_count" => 21, "matched_entities_truncated" => true)
    batch = AlertDigestPlanner.call(user:)
    SendAlertDigestJob.perform_now(batch.id)
    expect(ActionMailer::Base.deliveries.last.text_part.body.decoded).to include("Additional captured matches")
  end

  it "rechecks consent and rule revision before pending delivery and publication" do
    member
    rules = both
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    NotificationPreferences.update(user:, attributes: { email_enabled: false })
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
    rules.each { |rule| rule.setting.update!(revision: rule.setting.revision + 1) }
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDigestPlanner.call(user:)).to be_nil
    expect(AlertDelivery.sole.status).to eq("pending")
  end

  it "isolates account ownership and cleanup for the same cluster" do
    member
    both
    other = create(:user, email_address: "other-cluster@example.com")
    consent_email(other)
    create(:follow, user: other, followed_at: 1.year.ago, skip_default_alert_rule: true)
    %w[email in_app].each do |channel|
      rule = AlertRuleControl.create(user: other, attributes: { scope: "watchlist", event_type: "cluster", channel:, active: true }).rule
      rule.setting.update!(enabled_at: 1.year.ago)
    end
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    expect(InsiderClusterSnapshot.count).to eq(1)
    expect(AlertDelivery.count).to eq(2)
    travel 1.hour
    InAppNotificationPublisher.call
    expect(notices.size).to eq(1)
    post api_v1_notification_read_path(other.in_app_notifications.sole.id), headers: api_headers
    expect(response).to have_http_status(:not_found)
    AccountNotificationCleanup.call(user)
    user.destroy!
    expect(WatchlistFilingMembership.pluck(:user_id).uniq).to eq([ other.id ])
    expect(AlertDelivery.sole.alert_rule.user_id).to eq(other.id)
    expect(InsiderClusterSnapshot.count).to eq(1)
  end
end
