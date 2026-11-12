# frozen_string_literal: true

require "rails_helper"

RSpec.describe "In-app institutional position-change notifications" do
  include ApiAccounts
  include InstitutionalAlertHelpers
  around { |example| travel_to(Time.utc(2026, 11, 12, 11)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }
  let(:fund) { create(:institutional_filer) }

  def pro
    allow(Billing::Entitlements).to receive(:pro?).and_call_original
    allow(Billing::Entitlements).to receive(:pro?).with(user).and_return(true)
    allow(Billing::Entitlements).to receive(:pro_user_ids).and_return(User.where(id: user.id).select(:id))
  end

  def in_app_rule(conditions: {}, frequency: "daily_digest")
    follow = create(:follow, user:, target_type: "InstitutionalFiler", target_key: fund.cik, followed_at: 1.year.ago, skip_default_alert_rule: true)
    record = AlertRuleControl.create(user:, follow_id: follow.id,
      attributes: { channel: "in_app", event_type: "13f_change", active: true, frequency:,
        conditions: InstitutionalAlertConditions.normalize(conditions) }).rule
    record.setting.update!(enabled_at: 1.year.ago)
    record
  end

  def list(**parameters)
    get api_v1_notifications_path, params: parameters
    response.parsed_body.fetch("data")
  end

  it "supports fund-scoped typed API rules without email consent while gating instant delivery" do
    api_login(user)
    follow = create(:follow, user:, target_type: "InstitutionalFiler", target_key: fund.cik, skip_default_alert_rule: true)
    values = { follow_id: follow.id, channels: [ "in_app" ], trigger: "13f_change", active: true, frequency: "instant",
      conditions: { change_types: [ "reduced" ], direction: "decrease", cusip: "037833100", share_type: "SH", min_value: "100" } }
    post api_v1_alert_rules_path, params: values, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    pro
    post api_v1_alert_rules_path, params: values, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    _, current = alert_pair(fund:, before: 20, after: 10)
    # This accepted filing is newer than the rule activation in this API case.
    current.filing.update!(filed_at: Time.current)
    AlertEvaluator.call(current.filing)
    data = list.sole
    expect(data).to include("trigger" => "13f_change", "channel" => "in_app", "accession" => current.filing.accession_no)
    expect(data.fetch("position_change")).to include("change_type" => "reduced", "direction" => "decrease", "value_usd_delta" => "-100.0")
    expect(data.fetch("position_change").fetch("fund")).to include("cik" => fund.cik)
    expect(user.notification_preference).to be_nil
    expect(AlertDelivery.count).to eq(0)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "shares immutable comparison snapshots across channels, source evidence and retries" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    target = in_app_rule
    consent_email(user)
    email = AlertRuleControl.create(user:, follow_id: target.follow_id, attributes: { channel: "email", event_type: "13f_change", active: true }).rule
    email.setting.update!(enabled_at: 1.year.ago)
    prior, current = alert_pair(fund:)
    2.times { AlertEvaluator.call(current.filing) }
    snapshot = InstitutionalChangeSnapshot.sole
    expect(InAppNotification.sole.institutional_change_snapshot_id).to eq(AlertDelivery.sole.institutional_change_snapshot_id)
    expect(AlertRuleQuota.count(user)).to eq(1)
    expect { snapshot.update!(shares_delta: 999) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    row = InAppNotification.sole
    expect do
      InAppNotification.transaction(requires_new: true) { InAppNotification.insert_all!([ row.attributes.except("id") ]) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    change = list.sole.fetch("position_change")
    expect(change.fetch("current_sources").pluck("accession")).to eq([ current.filing.accession_no ])
    expect(change.fetch("prior_sources").pluck("accession")).to eq([ prior.filing.accession_no ])
  end

  [ [ nil, 20, "new" ], [ 20, nil, "exited" ], [ 20, 10, "reduced" ] ].each do |before, after, kind|
    it "classifies #{kind} using complete adjacent-quarter reports including valid empty tables" do
      pro
      api_login(user)
      in_app_rule(frequency: "instant")
      _, current = alert_pair(fund:, before:, after:)
      AlertEvaluator.call(current.filing)
      expect(list.sole.fetch("position_change").fetch("change_type")).to eq(kind)
    end
  end

  it "aggregates repeated CUSIPs but keeps put/call and principal keys separate" do
    pro
    api_login(user)
    in_app_rule(frequency: "instant")
    _, current = alert_pair(fund:)
    alert_holding(current, shares: 5, value_reported: 50, value_usd: 50, investment_discretion: "DFND")
    alert_holding(current, put_call: "PUT")
    alert_holding(current, share_type: "PRN")
    finish_alert_report(current)
    AlertEvaluator.call(current.filing)
    expect(InAppNotification.count).to eq(3)
    expect(list.size).to eq(3)
    expect(InstitutionalChangeSnapshot.find_by!(put_call: nil, share_type: "SH").shares_after).to eq(25)
  end

  it "leaves unknown normalized values null and prevents amount-threshold matches" do
    pro
    api_login(user)
    target = in_app_rule(frequency: "instant")
    _, current = alert_pair(fund:)
    current.institutional_holdings.sole.update!(value_usd: nil)
    AlertEvaluator.call(current.filing)
    change = list.sole.fetch("position_change")
    expect(change).to include("values_complete" => false, "value_usd_delta" => nil, "shares_delta" => "10.0")
    AlertRuleControl.update(user:, id: target.id, attributes: { active: false, conditions: InstitutionalAlertConditions.normalize({ "min_value" => "0" }) })
    AlertRuleControl.update(user:, id: target.id, active: true)
    next_report = alert_report(fund:, period: Date.new(2026, 9, 30), amendment_type: "RESTATEMENT", at: Time.current)
    alert_holding(next_report, shares: 30, value_reported: 300, value_usd: nil)
    finish_alert_report(next_report)
    expect { AlertEvaluator.call(next_report.filing) }.not_to change(InAppNotification, :count)
  end

  it "captures a delayed baseline with the comparison's actual primary filing and suppresses replaced report sets" do
    pro
    api_login(user)
    in_app_rule(frequency: "instant")
    prior, current = alert_pair(fund:)
    prior.update!(status: "pending")
    AlertEvaluator.call(current.filing)
    expect(InAppNotification.count).to eq(0)
    prior.update!(status: "parsed")
    AlertEvaluator.call(prior.filing)
    old = InAppNotification.sole
    expect(old.filing_id).to eq(current.filing_id)
    expect(old.published_at).to eq(Time.current)
    replacement = alert_report(fund:, period: prior.period_of_report, amendment_type: "RESTATEMENT", at: 1.minute.ago)
    alert_holding(replacement, shares: 5, value_reported: 50, value_usd: 50)
    finish_alert_report(replacement)
    AlertEvaluator.call(replacement.filing)
    fresh = InAppNotification.order(:id).last
    expect(fresh.filing_id).to eq(replacement.filing_id)
    expect(list.sole.fetch("position_change")).to include("shares_delta" => "15.0")
    expect(old.reload.published_at).not_to be_nil
    post api_v1_notification_read_path(old), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "suppresses queued comparisons after NEW HOLDINGS changes the effective report set" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    in_app_rule
    _, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    old = InAppNotification.sole
    addition = alert_report(fund:, amendment_type: "NEW HOLDINGS", at: 1.minute.ago)
    alert_holding(addition, shares: 5, value_reported: 50, value_usd: 50)
    finish_alert_report(addition)
    AlertEvaluator.call(addition.filing)
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    expect(old.reload.published_at).to be_nil
    expect(list.sole.fetch("position_change").fetch("shares_after")).to eq("25.0")
    get api_v1_notifications_summary_path
    expect(response.parsed_body.dig("data", "total_count")).to eq(1)
  end

  it "requires complete adjacent history and ignores notices and pre-activation reports" do
    pro
    api_login(user)
    target = in_app_rule(frequency: "instant")
    prior, current = alert_pair(fund:)
    prior.update!(status: "pending")
    AlertEvaluator.call(current.filing)
    expect(InAppNotification.count).to eq(0)
    prior.update!(status: "parsed")
    current.update!(table_entry_total: 999)
    AlertEvaluator.call(current.filing)
    expect(InAppNotification.count).to eq(0)
    finish_alert_report(current)
    target.setting.update!(enabled_at: Time.current)
    AlertEvaluator.call(current.filing)
    expect(InAppNotification.count).to eq(0)
    notice = alert_report(fund:, submission_type: "13F-NT", report_type: "13F NOTICE", at: Time.current)
    AlertEvaluator.call(notice.filing)
    expect(InAppNotification.count).to eq(0)
  end

  it "pins report contexts across a newly parsed amendment on an existing filing" do
    pro
    api_login(user)
    in_app_rule(frequency: "instant")
    _, current = alert_pair(fund:)
    alert_holding(current, put_call: "PUT")
    finish_alert_report(current)
    AlertEvaluator.call(current.filing)
    # The filing already exists at page one, but its report is ingested later.
    amendment_filing = create(:filing, cik: fund.cik, form_type: "13F-HR/A", filed_at: 30.minutes.ago)
    list(limit: 1)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    replacement = create(:institutional_report, filing: amendment_filing, institutional_filer: fund,
      period_of_report: current.period_of_report, filed_at: amendment_filing.filed_at, submission_type: "13F-HR/A", amendment_type: "RESTATEMENT")
    alert_holding(replacement, shares: 30, value_reported: 300, value_usd: 300)
    finish_alert_report(replacement)
    AlertEvaluator.call(amendment_filing)
    expect(list(limit: 1, cursor:).size).to eq(1)
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)
    expect(list.pluck("position_change").all? { |item| item["current_sources"].any? { |source| source["accession"] == amendment_filing.accession_no } }).to be(true)
  end

  it "rejects issuer-scoped rules and inconsistent institutional source references" do
    pro
    api_login(user)
    follow = create(:follow, user:, target_key: "ACME", skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: follow.id, channels: [ "in_app" ], trigger: "13f_change" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    in_app_rule(frequency: "instant")
    _, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
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
