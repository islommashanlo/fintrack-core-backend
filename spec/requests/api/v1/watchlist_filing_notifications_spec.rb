# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Watchlist filing notifications" do
  include ApiAccounts
  include OpenapiResponses
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 13, 11)) { example.run } }
  let(:user) { create(:user, password: "password123") }

  def follow(type: "Ticker", key: "ACME")
    create(:follow, user:, target_type: type, target_key: key, skip_default_alert_rule: true)
  end

  def activate(frequency: "daily_digest")
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    post api_v1_alert_rules_path, params: { scope: "watchlist", channels: [ "in_app" ],
      trigger: "new_filing", frequency:, active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    expect_documented_response(path: "/alert-rules", method: :post)
    AlertRule.find(response.parsed_body.dig("data", "id"))
  end

  def filing(**attributes)
    create(:filing, issuer_ticker: "ACME", filed_at: Time.current, **attributes)
  end

  def notices
    get api_v1_notifications_path
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/notifications", method: :get)
    response.parsed_body.fetch("data")
  end

  it "deduplicates overlapping issuer/person follows with immutable evidence and daily timing" do
    issuer = follow
    person = follow(type: "Insider", key: "0000000011")
    activate
    source = filing
    create(:insider_transaction, filing: source, insider_cik: person.target_key)
    2.times { AlertEvaluator.call(source) }
    expect(InAppNotification.count).to eq(1)
    expect(WatchlistFilingMembership.count).to eq(2)
    expect(notices).to eq([])
    expect(InAppNotification.sole.available_at).to eq(Time.utc(2026, 11, 13, 12))
    travel 1.hour
    InAppNotificationPublisher.call
    body = notices.sole
    expect(body).to include("entity" => { "type" => "watchlist", "key" => nil },
      "accession" => source.accession_no, "matched_entities_total_count" => 2, "matched_entities_truncated" => false)
    expect(body.fetch("matched_entities").pluck("follow_id")).to match_array([ issuer.id, person.id ])
    expect(body.fetch("matched_entities").pluck("type")).to match_array(%w[issuer person])
    expect { WatchlistFilingMembership.first.update!(target_key: "CHANGED") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(AlertDelivery.count).to eq(0)
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "keeps pending publication eligible through another captured membership but preserves published history after unfollow" do
    issuer = follow
    person = follow(type: "Insider", key: "0000000011")
    activate
    source = filing
    create(:insider_transaction, filing: source, insider_cik: person.target_key)
    AlertEvaluator.call(source)
    WatchlistMembership.remove(user:, id: issuer.id)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    WatchlistMembership.remove(user:, id: person.id)
    expect(notices.sole.fetch("matched_entities_total_count")).to eq(2)
    source.update!(parse_status: "failed")
    expect(notices).to eq([])
  end

  it "does not revive a pending notice by re-adding a follow or re-evaluating the same filing" do
    member = follow
    rule = activate
    source = filing
    AlertEvaluator.call(source)
    captured_epoch = WatchlistFilingMembership.sole.followed_at
    WatchlistMembership.remove(user:, id: member.id)
    travel 1.second
    WatchlistMembership.add(user:, target: FollowTarget::Target.new("Ticker", "ACME", "ACME"))
    expect(member.reload.followed_at).to be > captured_epoch
    AlertEvaluator.call(source)
    expect(WatchlistFilingMembership.count).to eq(1)
    expect(WatchlistFilingMembership.sole.followed_at).to eq(captured_epoch)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(notices).to eq([])
    expect(rule.reload).to be_active
  end

  it "matches institutional filing notices without requiring holdings and ignores unrelated, future and pre-membership filings" do
    fund = create(:institutional_filer)
    follow(type: "InstitutionalFiler", key: fund.cik)
    activate
    source = create_13f(fund:, filed_at: Time.current, submission_type: "13F-NT", report_type: "13F NOTICE")
    AlertEvaluator.call(source.filing)
    AlertEvaluator.call(filing)
    [ 1.day.ago, 1.day.from_now ].each do |time|
      item = create_13f(fund:, filed_at: time, submission_type: "13F-NT", report_type: "13F NOTICE")
      AlertEvaluator.call(item.filing)
    end
    expect(InAppNotification.count).to eq(1)
    expect(InAppNotification.sole.filing_id).to eq(source.filing_id)
    expect(WatchlistFilingMembership.sole.target_key).to eq(fund.cik)
  end

  it "keeps other watchlist triggers inactive even when database validations are bypassed" do
    activate
    %w[email in_app].each do |channel|
      trigger = "insider_transaction"
      rule = user.alert_rules.create!(scope: "watchlist", channel:, event_type: trigger)
      patch api_v1_alert_rule_path(rule), params: { active: true }, headers: api_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect do
        ApplicationRecord.transaction(requires_new: true) { rule.update_columns(active: true) }
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end


  it "rolls capture back atomically and rejects another owner's witness even without validation" do
    member = follow
    activate
    source = filing
    ApplicationRecord.transaction(requires_new: true) do
      WatchlistFilingNotificationMatcher.call(source)
      expect(InAppNotification.count).to eq(1)
      expect(WatchlistFilingMembership.count).to eq(1)
      raise ActiveRecord::Rollback
    end
    expect(InAppNotification.count).to eq(0)
    expect(WatchlistFilingMembership.count).to eq(0)
    WatchlistFilingNotificationMatcher.call(source)
    witness = WatchlistFilingMembership.sole
    other = create(:user, email_address: "other@example.com")
    foreign = create(:follow, user: other, skip_default_alert_rule: true)
    attributes = witness.attributes.except("id").merge("follow_id" => foreign.id)
    expect do
      ApplicationRecord.transaction(requires_new: true) { WatchlistFilingMembership.insert_all!([ attributes ]) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    expect(witness.follow_id).to eq(member.id)
  end

  it "publishes verified Pro instant notices with bounded source evidence" do
    with_billing_config do
      bind_billing_customer(user)
      apply_billing_event
      members = 21.times.map { |i| follow(type: "Insider", key: format("%010d", i + 1)) }
      activate(frequency: "instant")
      source = filing
      members.each_with_index do |member, i|
        create(:insider_transaction, filing: source, insider_cik: member.target_key, owner_seq: i + 1)
      end
      AlertEvaluator.call(source)
      expect(InAppNotification.sole.published_at).to eq(Time.current)
      body = notices.sole
      expect(body).to include("matched_entities_total_count" => 21, "matched_entities_truncated" => true)
      expect(body.fetch("matched_entities").size).to eq(20)
      expect(WatchlistFilingMembership.count).to eq(21)
    end
  end

  it "keeps same-entity accounts private and cleans up only the deleted account's witnesses" do
    follow
    activate
    other = create(:user, email_address: "other@example.com")
    create(:follow, user: other, skip_default_alert_rule: true)
    NotificationPreferences.update(user: other, attributes: { time_zone: "America/New_York" })
    AlertRuleControl.create(user: other, attributes: { scope: "watchlist", channel: "in_app", event_type: "new_filing", active: true })
    source = filing
    AlertEvaluator.call(source)
    expect(WatchlistFilingMembership.count).to eq(2)
    travel 1.hour
    InAppNotificationPublisher.call
    owned = notices.sole
    expect(InAppNotification.count).to eq(2)
    post api_v1_notification_read_path(owned.fetch("id")), headers: api_headers
    expect(response).to have_http_status(:ok)
    expect(notices.sole.fetch("read_at")).to be_present
    AccountNotificationCleanup.call(user)
    user.destroy!
    expect(WatchlistFilingMembership.sole.user_id).to eq(other.id)
    expect(InAppNotification.sole.alert_rule.user_id).to eq(other.id)
    expect(source.reload.parse_status).to eq("parsed")
  end

  it "quotes as-reported source ticker punctuation without reinterpreting named bind tokens" do
    member = follow(type: "Insider", key: "0000000011")
    activate
    source = filing(issuer_ticker: "O'NEIL:source")
    create(:insider_transaction, filing: source, insider_cik: member.target_key)
    expect { AlertEvaluator.call(source) }.not_to raise_error
    expect(InAppNotification.count).to eq(1)
  end
end
