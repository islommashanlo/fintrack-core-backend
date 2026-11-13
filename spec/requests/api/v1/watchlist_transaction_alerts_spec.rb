# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Watchlist insider transaction alerts" do
  include ApiAccounts
  include OpenapiResponses
  around { |example| travel_to(Time.utc(2026, 11, 13, 11)) { example.run } }
  let(:user) { create(:user, password: "password123") }

  def follow(type: "Ticker", key: "ACME")
    create(:follow, user:, target_type: type, target_key: key, skip_default_alert_rule: true)
  end

  def activate(channel:, conditions: {}, frequency: "daily_digest")
    channel == "email" ? consent_email(user) : NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    post api_v1_alert_rules_path, params: { scope: "watchlist", trigger: "insider_transaction",
      channels: [ channel ], conditions:, frequency:, active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    expect_documented_response(path: "/alert-rules", method: :post)
    AlertRule.find(response.parsed_body.dig("data", "id"))
  end

  def source(**attributes)
    create(:filing, issuer_ticker: "ACME", filed_at: Time.current, **attributes)
  end

  def notices
    get api_v1_notifications_path
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/notifications", method: :get)
    response.parsed_body.fetch("data")
  end

  it "deduplicates overlap and joint owners by table/line while retaining an eligible owner" do
    issuer = follow
    person = follow(type: "Insider", key: "0000000789")
    conditions = { direction: "purchase", codes: [ "p" ], type: "open_market", role: "officer", min_value: "1000" }
    activate(channel: "email", conditions:)
    activate(channel: "in_app", conditions:)
    filing = source
    first = create(:insider_transaction, filing:, price: 20, shares: 100)
    eligible = create(:insider_transaction, filing:, insider_cik: person.target_key, owner_seq: 2,
      txn_seq: first.txn_seq, price: 20, shares: 100, is_officer: true)
    derivative = create(:insider_transaction, filing:, security_table: "derivative", txn_seq: first.txn_seq,
      price: 20, shares: 100, is_officer: true)
    create(:insider_transaction, filing:, transaction_code: "S", is_officer: true)
    create(:insider_transaction, filing:, price: nil, is_officer: true)
    create(:insider_transaction, filing:, price_suspect: true, is_officer: true)
    2.times { AlertEvaluator.call(filing) }
    expect(AlertDelivery.count).to eq(2)
    expect(InAppNotification.count).to eq(2)
    expect(AlertDelivery.pluck(:insider_transaction_id)).to match_array([ eligible.id, derivative.id ])
    expect(InAppNotification.pluck(:insider_transaction_id)).to match_array([ eligible.id, derivative.id ])
    expect(AlertDelivery.pluck(:watchlist_security_table)).to match_array(%w[non_derivative derivative])
    delivery = AlertDelivery.find_by!(insider_transaction_id: eligible.id)
    expect(WatchlistFilingMembership.where(alert_delivery_id: delivery.id).pluck(:follow_id)).to match_array([ issuer.id, person.id ])
    expect(AlertRuleQuota.count(user)).to eq(1)
    travel 1.hour
    InAppNotificationPublisher.call
    expect(notices.map { |row| row.dig("transaction", "id") }).to match_array([ eligible.id, derivative.id ])
    batch = AlertDigestPlanner.call(user:)
    SendAlertDigestJob.perform_now(batch.id)
    expect(ActionMailer::Base.deliveries.last.text_part.body.decoded).to include("reported", filing.sec_url)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "does not create a second email when the representative owner's follow is removed" do
    first_member = follow(type: "Insider", key: "0000000456")
    second_member = follow(type: "Insider", key: "0000000789")
    activate(channel: "email")
    activate(channel: "in_app")
    filing = source
    first = create(:insider_transaction, filing:)
    create(:insider_transaction, filing:, insider_cik: second_member.target_key, owner_seq: 2, txn_seq: first.txn_seq)
    AlertEvaluator.call(filing)
    pointer = AlertDelivery.sole.insider_transaction_id
    WatchlistMembership.remove(user:, id: first_member.id)
    AlertEvaluator.call(filing)
    expect(AlertDelivery.count).to eq(1)
    expect(InAppNotification.count).to eq(1)
    expect(AlertDelivery.sole.insider_transaction_id).to eq(pointer)
    expect(WatchlistFilingMembership.count).to eq(4)
    travel 1.hour
    InAppNotificationPublisher.call
    expect(notices.sole.fetch("matched_entities_total_count")).to eq(2)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest").pluck(:id)).to eq([ AlertDelivery.sole.id ])
  end

  it "captures witnesses per line so an unrelated live match cannot release another line" do
    first_member = follow(type: "Insider", key: "0000000456")
    second_member = follow(type: "Insider", key: "0000000789")
    activate(channel: "email")
    activate(channel: "in_app")
    filing = source
    first = create(:insider_transaction, filing:)
    second = create(:insider_transaction, filing:, insider_cik: second_member.target_key)
    AlertEvaluator.call(filing)
    WatchlistMembership.remove(user:, id: first_member.id)
    travel 1.second
    WatchlistMembership.add(user:, target: FollowTarget::Target.new("Insider", first_member.target_key, "Example"))
    AlertEvaluator.call(filing)
    expect(AlertDelivery.count).to eq(2)
    expect(WatchlistFilingMembership.count).to eq(4)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(notices.sole.dig("transaction", "id")).to eq(second.id)
    eligible = AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")
    expect(eligible.pluck(:insider_transaction_id)).to eq([ second.id ])
    expect(eligible.pluck(:insider_transaction_id)).not_to include(first.id)
  end

  it "keeps original rows but suppresses superseded transaction alerts and matches the amendment" do
    follow
    activate(channel: "email")
    activate(channel: "in_app")
    original = source
    create(:insider_transaction, filing: original)
    AlertEvaluator.call(original)
    travel 1.second
    amendment = source(form_type: "4/A", amends_accession_no: original.accession_no)
    amended = create(:insider_transaction, filing: amendment)
    AlertEvaluator.call(amendment)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(notices.sole.dig("transaction", "id")).to eq(amended.id)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest").pluck(:filing_id)).to eq([ amendment.id ])
    expect(AlertDelivery.count).to eq(2)
    expect(InAppNotification.count).to eq(2)
  end

  it "does not reinterpret missing or suspect prices as zero, and supports administrative directions" do
    follow
    activate(channel: "in_app", conditions: { min_value: 0 })
    filing = source
    create(:insider_transaction, filing:, price: nil)
    create(:insider_transaction, filing:, price_suspect: true)
    zero = create(:insider_transaction, filing:, price: 0, transaction_code: "A")
    AlertEvaluator.call(filing)
    expect(InAppNotification.pluck(:insider_transaction_id)).to eq([ zero.id ])
  end

  it "enforces email line identity even when validation is bypassed" do
    follow
    activate(channel: "email")
    filing = source
    first = create(:insider_transaction, filing:)
    second = create(:insider_transaction, filing:)
    AlertEvaluator.call(filing)
    delivery = AlertDelivery.find_by!(insider_transaction_id: first.id)
    expect do
      ApplicationRecord.transaction(requires_new: true) { delivery.update_columns(watchlist_txn_seq: first.txn_seq + 1_000_000) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    attrs = delivery.attributes.except("id").merge("insider_transaction_id" => second.id)
    expect do
      ApplicationRecord.transaction(requires_new: true) { AlertDelivery.insert_all!([ attrs ]) }
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "delivers verified Pro instant transaction email and in-app evidence without enabling other triggers" do
    with_billing_config do
      bind_billing_customer(user)
      apply_billing_event
      follow
      activate(channel: "email", frequency: "instant", conditions: { direction: "sale" })
      activate(channel: "in_app", frequency: "instant", conditions: { direction: "sale" })
      filing = source
      transaction = create(:insider_transaction, filing:, transaction_code: "S", acquired_disposed: "D")
      AlertEvaluator.call(filing)
      expect(notices.sole.dig("transaction", "id")).to eq(transaction.id)
      expect { SendAlertJob.perform_now(AlertDelivery.sole.id) }.to change { ActionMailer::Base.deliveries.length }.by(1)
      expect(ActionMailer::Base.deliveries.last.subject).to eq("Reported insider transaction for your watchlist")
      expect { SendAlertJob.perform_now(AlertDelivery.sole.id) }.not_to change { ActionMailer::Base.deliveries.length }
    end
  end
  it "isolates same-entity owners and preserves the other account during cleanup" do
    follow
    activate(channel: "email")
    activate(channel: "in_app")
    other = create(:user, email_address: "other-transaction@example.com")
    consent_email(other)
    create(:follow, user: other, skip_default_alert_rule: true)
    %w[email in_app].each do |channel|
      AlertRuleControl.create(user: other, attributes: { scope: "watchlist", event_type: "insider_transaction", channel:, active: true })
    end
    filing = source
    create(:insider_transaction, filing:)
    AlertEvaluator.call(filing)
    expect(AlertDelivery.count).to eq(2)
    expect(InAppNotification.count).to eq(2)
    travel 1.hour
    InAppNotificationPublisher.call
    expect(notices.size).to eq(1)
    get api_v1_alert_events_path, params: { scope: "watchlist" }
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/alert-events", method: :get)
    expect(response.parsed_body.fetch("data").size).to eq(1)
    foreign = other.in_app_notifications.sole
    post api_v1_notification_read_path(foreign.id), headers: api_headers
    expect(response).to have_http_status(:not_found)
    AccountNotificationCleanup.call(user)
    user.destroy!
    expect(WatchlistFilingMembership.pluck(:user_id).uniq).to eq([ other.id ])
    expect(AlertDelivery.sole.alert_rule.user_id).to eq(other.id)
    expect(InAppNotification.sole.alert_rule.user_id).to eq(other.id)
  end

  it "does not match historical, future, failed, unrelated or fund-only sources" do
    follow
    activate(channel: "in_app")
    [ source(filed_at: 1.hour.ago), source(filed_at: 1.hour.from_now), source(parse_status: "failed"),
      source(issuer_ticker: "OTHER") ].each do |filing|
      create(:insider_transaction, filing:)
      AlertEvaluator.call(filing)
    end
    expect(InAppNotification.count).to eq(0)
    user.follows.current.each { |member| WatchlistMembership.remove(user:, id: member.id) }
    fund = create(:institutional_filer)
    follow(type: "InstitutionalFiler", key: fund.cik)
    filing = source
    create(:insider_transaction, filing:)
    AlertEvaluator.call(filing)
    expect(WatchlistFilingMembership.count).to eq(0)
  end
end
