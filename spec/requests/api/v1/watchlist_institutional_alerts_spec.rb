# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Watchlist 13F change alerts" do
  include ApiAccounts
  include OpenapiResponses
  include InstitutionalAlertHelpers
  around { |example| travel_to(Time.utc(2026, 11, 13, 11)) { example.run } }
  let(:user) { create(:user, password: "password123") }
  let(:fund) { create(:institutional_filer) }

  def member(target: fund)
    create(:follow, user:, target_type: "InstitutionalFiler", target_key: target.cik,
      followed_at: 1.year.ago, skip_default_alert_rule: true)
  end

  def activate(channel:, conditions: {}, frequency: "daily_digest")
    channel == "email" ? consent_email(user) : NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    post api_v1_alert_rules_path, params: { scope: "watchlist", trigger: "13f_change", channels: [ channel ],
      active: true, conditions:, frequency: }, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    expect_documented_response(path: "/alert-rules", method: :post)
    expect(response.parsed_body.dig("meta", "watchlist_#{channel}_supported_triggers")).to include("13f_change")
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

  it "shares immutable comparison evidence, captures fund membership and deduplicates both channels" do
    watched = member
    both
    prior, current = alert_pair(fund:)
    2.times { AlertEvaluator.call(current.filing) }
    snapshot = InstitutionalChangeSnapshot.sole
    expect(snapshot).to have_attributes(current_report_ids: [ current.id ], prior_report_ids: [ prior.id ], shares_delta: 10.to_d)
    expect(AlertDelivery.sole.institutional_change_snapshot_id).to eq(InAppNotification.sole.institutional_change_snapshot_id)
    expect(WatchlistFilingMembership.pluck(:follow_id)).to eq([ watched.id, watched.id ])
    expect(AlertRuleQuota.count(user)).to eq(1)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    row = notices.sole
    expect(row.fetch("entity")).to include("type" => "watchlist", "key" => nil)
    expect(row.fetch("matched_entities").sole.fetch("follow_id")).to eq(watched.id)
    expect(row.dig("position_change", "fund", "cik")).to eq(fund.cik)
    batch = AlertDigestPlanner.call(user:)
    SendAlertDigestJob.perform_now(batch.id)
    expect(ActionMailer::Base.deliveries.last.text_part.body.decoded).to include("classified as added", fund.cik, prior.filing.sec_url, current.filing.sec_url)
    get api_v1_alert_events_path, params: { scope: "watchlist" }
    expect_documented_response(path: "/alert-events", method: :get)
    expect(response.parsed_body.fetch("data").sole.fetch("matched_entities_total_count")).to eq(1)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "aggregates repeated CUSIPs while keeping options and principal positions distinct" do
    member
    both
    _, current = alert_pair(fund:)
    alert_holding(current, shares: 5, value_reported: 50, value_usd: 50, investment_discretion: "DFND")
    alert_holding(current, put_call: "PUT")
    alert_holding(current, share_type: "PRN")
    finish_alert_report(current)
    2.times { AlertEvaluator.call(current.filing) }
    expect(AlertDelivery.count).to eq(3)
    expect(InAppNotification.count).to eq(3)
    expect(WatchlistFilingMembership.count).to eq(6)
    expect(InstitutionalChangeSnapshot.find_by!(put_call: nil, share_type: "SH").shares_after).to eq(25)
  end

  [ [ nil, 20, "new" ], [ 20, nil, "exited" ], [ 20, 10, "reduced" ] ].each do |before, after, kind|
    it "matches #{kind} with complete adjacent reports, including valid empty tables" do
      member
      both(conditions: { change_types: [ kind ] })
      _, current = alert_pair(fund:, before:, after:)
      AlertEvaluator.call(current.filing)
      travel 1.hour
      InAppNotificationPublisher.call
      expect(notices.sole.dig("position_change", "change_type")).to eq(kind)
      expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest").count).to eq(1)
    end
  end

  it "rechecks captured epochs without appending re-added or unrelated fund memberships" do
    watched = member
    both
    _, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    evidence = WatchlistFilingMembership.order(:id).map(&:attributes)
    WatchlistMembership.remove(user:, id: watched.id)
    travel 1.second
    WatchlistMembership.add(user:, target: FollowTarget::Target.new("InstitutionalFiler", fund.cik, fund.name))
    member(target: create(:institutional_filer))
    AlertEvaluator.call(current.filing)
    expect(AlertDelivery.count).to eq(1)
    expect(WatchlistFilingMembership.order(:id).map(&:attributes)).to eq(evidence)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
  end

  it "keeps one fund's live membership from releasing another fund's pending comparison" do
    watched = member
    other = create(:institutional_filer)
    member(target: other)
    both
    _, first = alert_pair(fund:)
    _, second = alert_pair(fund: other)
    [ first, second ].each { |report| AlertEvaluator.call(report.filing) }
    WatchlistMembership.remove(user:, id: watched.id)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(notices.sole.dig("position_change", "fund", "cik")).to eq(other.cik)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest").pluck(:filing_id)).to eq([ second.filing_id ])
  end

  it "resolves restatements and additive amendments and invalidates older report sets without deleting history" do
    member
    both
    prior, original = alert_pair(fund:)
    AlertEvaluator.call(original.filing)
    old = AlertDelivery.sole
    replacement = alert_report(fund:, amendment_type: "RESTATEMENT", at: 30.minutes.ago)
    alert_holding(replacement, shares: 30, value_reported: 300, value_usd: 300)
    finish_alert_report(replacement)
    AlertEvaluator.call(replacement.filing)
    addition = alert_report(fund:, amendment_type: "NEW HOLDINGS", at: 1.minute.ago)
    alert_holding(addition, shares: 5, value_reported: 50, value_usd: 50)
    finish_alert_report(addition)
    AlertEvaluator.call(addition.filing)
    snapshot = InstitutionalChangeSnapshot.order(:id).last
    expect(snapshot).to have_attributes(shares_after: 35.to_d, current_report_ids: [ replacement.id, addition.id ], prior_report_ids: [ prior.id ])
    expect(snapshot.evidence_report_ids).to include(original.id)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(notices.sole.dig("position_change", "shares_after")).to eq("35.0")
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest").pluck(:institutional_change_snapshot_id)).to eq([ snapshot.id ])
    expect(old.reload.status).to eq("pending")
    expect(InstitutionalChangeSnapshot.count).to eq(3)
  end

  it "uses the actual primary filing when a delayed baseline enables verified Pro instant alerts" do
    with_billing_config do
      bind_billing_customer(user)
      apply_billing_event
      member
      both(frequency: "instant")
      prior, current = alert_pair(fund:)
      prior.update!(status: "pending")
      AlertEvaluator.call(current.filing)
      expect(AlertDelivery.count).to eq(0)
      prior.update!(status: "parsed")
      AlertEvaluator.call(prior.filing)
      delivery = AlertDelivery.sole
      expect(delivery.filing_id).to eq(current.filing_id)
      expect(WatchlistFilingMembership.pluck(:filing_id).uniq).to eq([ current.filing_id ])
      expect(InAppNotification.sole.published_at).to eq(Time.current)
      expect(notices.sole.fetch("accession")).to eq(current.filing.accession_no)
      expect(SendAlertJob).to have_been_enqueued.with(delivery.id)
      2.times { SendAlertJob.perform_now(delivery.id) }
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(ActionMailer::Base.deliveries.last.subject).to eq("Reported 13F position change for your watchlist")
    end
  end

  it "leaves unknown values null and does not match an amount threshold even at zero" do
    member
    rules = both
    _, current = alert_pair(fund:)
    current.institutional_holdings.sole.update!(value_usd: nil)
    AlertEvaluator.call(current.filing)
    expect(InstitutionalChangeSnapshot.sole).to have_attributes(values_complete: false, value_usd_delta: nil, shares_delta: 10.to_d)
    rules.each do |rule|
      AlertRuleControl.update(user:, id: rule.id, attributes: { active: false, conditions: InstitutionalAlertConditions.normalize({ "min_value" => "0" }) })
      enable_rule(rule)
    end
    changed = alert_report(fund:, amendment_type: "RESTATEMENT", at: Time.current)
    alert_holding(changed, shares: 30, value_reported: 300, value_usd: nil)
    finish_alert_report(changed)
    expect { AlertEvaluator.call(changed.filing) }.not_to change(AlertDelivery, :count)
    expect(InAppNotification.count).to eq(1)
  end

  it "requires complete adjacent history and ignores notices, future and pre-activation sources" do
    member
    rules = both
    prior, current = alert_pair(fund:)
    prior.update!(period_of_report: Date.new(2026, 3, 31))
    AlertEvaluator.call(current.filing)
    prior.update!(period_of_report: Date.new(2026, 6, 30))
    current.update!(table_entry_total: 999)
    AlertEvaluator.call(current.filing)
    finish_alert_report(current)
    rules.each { |rule| rule.setting.update!(enabled_at: Time.current) }
    AlertEvaluator.call(current.filing)
    [ alert_report(fund:, submission_type: "13F-NT", report_type: "13F NOTICE", at: Time.current),
      alert_report(fund:, at: 1.day.from_now) ].each { |report| AlertEvaluator.call(report.filing) }
    expect(AlertDelivery.count).to eq(0)
    expect(InAppNotification.count).to eq(0)
  end

  it "matches inclusive absolute-value and security filters for reported reductions" do
    member
    both(conditions: { change_types: [ "reduced" ], direction: "decrease", cusip: "037833100", share_type: "SH", min_value: "100" })
    _, current = alert_pair(fund:, before: 20, after: 10)
    AlertEvaluator.call(current.filing)
    expect(InstitutionalChangeSnapshot.sole.value_usd_delta).to eq(-100)
    expect(AlertDelivery.count).to eq(1)
    expect(InAppNotification.count).to eq(1)
  end

  it "uses an amended baseline as primary evidence and suppresses the previous comparison" do
    member
    both
    prior, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    replacement = alert_report(fund:, period: prior.period_of_report, amendment_type: "RESTATEMENT", at: 1.minute.ago)
    alert_holding(replacement, shares: 5, value_reported: 50, value_usd: 50)
    finish_alert_report(replacement)
    AlertEvaluator.call(replacement.filing)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(notices.sole.fetch("accession")).to eq(replacement.filing.accession_no)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest").pluck(:filing_id)).to eq([ replacement.filing_id ])
  end

  it "rechecks consent and configuration revisions before sending or publishing pending comparisons" do
    member
    rules = both
    _, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    NotificationPreferences.update(user:, attributes: { email_enabled: false })
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
    rules.each { |rule| rule.setting.update!(revision: rule.setting.revision + 1) }
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDigestPlanner.call(user:)).to be_nil
  end

  it "ignores issuer/person follows and isolates matching fund owners and cleanup" do
    create(:follow, user:, skip_default_alert_rule: true)
    both
    _, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    expect(AlertDelivery.count).to eq(0)
    member
    other = create(:user, email_address: "other-institutional@example.com")
    consent_email(other)
    create(:follow, user: other, target_type: "InstitutionalFiler", target_key: fund.cik, followed_at: 1.year.ago, skip_default_alert_rule: true)
    %w[email in_app].each do |channel|
      rule = AlertRuleControl.create(user: other, attributes: { scope: "watchlist", event_type: "13f_change", channel:, active: true }).rule
      rule.setting.update!(enabled_at: 1.year.ago)
    end
    AlertEvaluator.call(current.filing)
    expect(InstitutionalChangeSnapshot.count).to eq(1)
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
    expect(InstitutionalChangeSnapshot.count).to eq(1)
  end
end
