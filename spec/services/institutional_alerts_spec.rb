# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Institutional position-change alerts" do
  include InstitutionalAlertHelpers
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  let(:user) { create(:user) }
  let(:fund) { create(:institutional_filer) }
  before { consent_email(user) }

  it "captures adjacent-quarter changes and source evidence once across retries" do
    rule = institutional_rule(user:, fund:)
    previous, current = alert_pair(fund:)
    expect { AlertEvaluator.call(current.filing) }.to change(AlertDelivery, :count).by(1)
    snapshot = InstitutionalChangeSnapshot.sole
    expect(snapshot).to have_attributes(change_type: "add", shares_before: 10.to_d, shares_after: 20.to_d,
      shares_delta: 10.to_d, value_usd_delta: 100.to_d, values_complete: true,
      current_report_ids: [ current.id ], prior_report_ids: [ previous.id ])
    expect(rule.alert_deliveries.sole.institutional_change_snapshot_id).to eq(snapshot.id)
    expect { AlertEvaluator.call(current.filing) }.not_to change(AlertDelivery, :count)
    expect(InstitutionalChangeSnapshot.count).to eq(1)
    expect { snapshot.update!(shares_delta: 999) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(SendAlertJob).not_to have_been_enqueued
  end

  [ [ nil, 20, "new" ], [ 20, nil, "exit" ], [ 20, 10, "trim" ] ].each do |before, after, kind|
    it "classifies #{kind} using valid empty reports as absence evidence" do
      institutional_rule(user:, fund:)
      previous, current = alert_pair(fund:, before:, after:)
      AlertEvaluator.call(current.filing)
      expect(InstitutionalChangeSnapshot.sole).to have_attributes(change_type: kind,
        current_report_ids: [ current.id ], prior_report_ids: [ previous.id ])
    end
  end

  it "aggregates repeated CUSIPs but keeps option and principal keys separate" do
    institutional_rule(user:, fund:)
    previous, current = alert_pair(fund:)
    alert_holding(current, shares: 5, value_reported: 50, value_usd: 50, investment_discretion: "DFND")
    alert_holding(current, put_call: "PUT")
    alert_holding(current, share_type: "PRN")
    finish_alert_report(current)
    AlertEvaluator.call(current.filing)
    expect(InstitutionalChangeSnapshot.count).to eq(3)
    plain = InstitutionalChangeSnapshot.find_by!(put_call: nil, share_type: "SH")
    expect(plain.shares_after).to eq(25)
    expect(plain.prior_report_ids).to eq([ previous.id ])
  end

  it "matches typed change, direction, security and inclusive absolute-value filters" do
    rule = institutional_rule(user:, fund:, conditions: { "change_types" => [ "reduced" ], "direction" => "decrease",
      "cusip" => "037833100", "share_type" => "SH", "min_value" => "100" })
    _, current = alert_pair(fund:, before: 20, after: 10)
    AlertEvaluator.call(current.filing)
    expect(rule.alert_deliveries.count).to eq(1)
    expect(InstitutionalChangeSnapshot.sole.value_usd_delta).to eq(-100)
  end

  it "requires adjacent complete structure and never infers a new position from missing history" do
    institutional_rule(user:, fund:)
    previous, current = alert_pair(fund:)
    previous.update!(period_of_report: Date.new(2026, 3, 31))
    expect { AlertEvaluator.call(current.filing) }.not_to change(AlertDelivery, :count)
    previous.update!(period_of_report: Date.new(2026, 6, 30))
    [ { table_entry_total: 999 }, { table_value_total: 999 }, { suspect: true }, { status: "failed" } ].each do |attributes|
      current.update!(table_entry_total: 1, table_value_total: 200, suspect: false, status: "parsed", **attributes)
      expect { AlertEvaluator.call(current.filing) }.not_to change(AlertDelivery, :count)
    end
  end

  it "leaves unnormalized values unknown and never matches an amount threshold with them" do
    institutional_rule(user:, fund:)
    _, current = alert_pair(fund:)
    current.institutional_holdings.sole.update!(value_usd: nil)
    AlertEvaluator.call(current.filing)
    expect(InstitutionalChangeSnapshot.sole).to have_attributes(values_complete: false, value_usd_delta: nil, shares_delta: 10.to_d)
    delivery = AlertDelivery.sole
    AlertRuleControl.update(user:, id: delivery.alert_rule_id, attributes: { active: false, conditions: { "min_value" => "0.0" } })
    enable_rule(delivery.alert_rule)
    expect { AlertEvaluator.call(current.filing) }.not_to change(AlertDelivery, :count)
  end

  it "validates normalized thousands without changing reported values" do
    institutional_rule(user:, fund:)
    previous, current = alert_pair(fund:)
    [ previous, current ].each do |report|
      report.update!(cover_value_unit: "thousands")
      report.institutional_holdings.each { |h| h.update!(value_unit: "thousands", value_usd: h.value_reported * 1000) }
    end
    AlertEvaluator.call(current.filing)
    expect(InstitutionalChangeSnapshot.sole.value_usd_delta).to eq(100000)
    expect(current.institutional_holdings.sole.value_reported).to eq(200)
  end

  it "reevaluates a later quarter when a delayed baseline arrives" do
    rule = institutional_rule(user:, fund:)
    previous, current = alert_pair(fund:)
    previous.update!(status: "pending")
    expect { AlertEvaluator.call(current.filing) }.not_to change(AlertDelivery, :count)
    previous.update!(status: "parsed")
    AlertEvaluator.call(previous.filing)
    expect(rule.alert_deliveries.sole.filing_id).to eq(current.filing_id)
  end

  it "resolves RESTATEMENT and NEW HOLDINGS, retaining originals as evidence and invalidating prior queued contexts" do
    institutional_rule(user:, fund:)
    previous, original = alert_pair(fund:)
    AlertEvaluator.call(original.filing)
    old = AlertDelivery.sole
    replacement = alert_report(fund:, amendment_type: "RESTATEMENT", at: 30.minutes.ago)
    alert_holding(replacement, shares: 30, value_reported: 300, value_usd: 300)
    finish_alert_report(replacement)
    AlertEvaluator.call(replacement.filing)
    expect(AlertDeliveryPolicy.eligible?(old, user:, frequency: "daily_digest")).to be(false)
    addition = alert_report(fund:, amendment_type: "NEW HOLDINGS", at: 10.minutes.ago)
    alert_holding(addition, shares: 5, value_reported: 50, value_usd: 50)
    finish_alert_report(addition)
    newer = AlertDelivery.order(:id).last
    AlertEvaluator.call(addition.filing)
    snapshot = InstitutionalChangeSnapshot.order(:id).last
    expect(snapshot).to have_attributes(shares_after: 35.to_d, current_report_ids: [ replacement.id, addition.id ], prior_report_ids: [ previous.id ])
    expect(snapshot.evidence_report_ids).to include(original.id)
    expect(AlertDeliveryPolicy.eligible?(newer, user:, frequency: "daily_digest")).to be(false)
    expect(old.reload.status).to eq("pending")
  end

  it "requires resolvable originals and handles originals parsed after their restatements" do
    institutional_rule(user:, fund:)
    _, current = alert_pair(fund:)
    current.update!(status: "pending")
    replacement = alert_report(fund:, amendment_type: "RESTATEMENT", at: 30.minutes.ago)
    alert_holding(replacement, shares: 30, value_reported: 300, value_usd: 300)
    finish_alert_report(replacement)
    expect { AlertEvaluator.call(replacement.filing) }.not_to change(AlertDelivery, :count)
    current.update!(status: "parsed")
    AlertEvaluator.call(current.filing)
    expect(InstitutionalChangeSnapshot.sole.current_report_ids).to eq([ replacement.id ])
  end

  it "ignores notices, orphan additions, stale activations, future sources and invalid rows" do
    rule = institutional_rule(user:, fund:)
    _, current = alert_pair(fund:)
    rule.setting.update!(enabled_at: Time.current)
    expect { AlertEvaluator.call(current.filing) }.not_to change(AlertDelivery, :count)
    rule.setting.update!(enabled_at: 1.year.ago)
    current.institutional_holdings.sole.update!(cusip: "INVALID")
    expect { AlertEvaluator.call(current.filing) }.not_to change(AlertDelivery, :count)
    notice = alert_report(fund:, submission_type: "13F-NT", report_type: "13F NOTICE")
    expect { AlertEvaluator.call(notice.filing) }.not_to change(AlertDelivery, :count)
    future = alert_report(fund:, at: 1.day.from_now)
    expect { AlertEvaluator.call(future.filing) }.not_to change(AlertDelivery, :count)
  end

  it "sends factual digest evidence through the test adapter" do
    rule = institutional_rule(user:, fund:)
    previous, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    travel 1.day
    batch = AlertDigestPlanner.call(user:)
    SendAlertDigestJob.perform_now(batch.id)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.text_part.body.decoded).to include("classified as added", "037833100", previous.filing.sec_url, current.filing.sec_url)
    expect(mail["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
    expect(rule.alert_deliveries.sole.status).to eq("sent")
  end

  it "reevaluates the next quarter after a baseline amendment and suppresses the older comparison" do
    institutional_rule(user:, fund:)
    previous, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    old = AlertDelivery.sole
    replacement = alert_report(fund:, period: previous.period_of_report, amendment_type: "RESTATEMENT", at: 1.minute.ago)
    alert_holding(replacement, shares: 5, value_reported: 50, value_usd: 50)
    finish_alert_report(replacement)
    AlertEvaluator.call(replacement.filing)
    snapshot = InstitutionalChangeSnapshot.order(:id).last
    expect(snapshot).to have_attributes(period_of_report: current.period_of_report, shares_delta: 15.to_d,
      prior_report_ids: [ replacement.id ], primary_filing_id: replacement.filing_id)
    expect(AlertDeliveryPolicy.eligible?(old, user:, frequency: "daily_digest")).to be(false)
  end

  it "checks paid instant access before sending, escapes source text and stays idempotent" do
    allow(PlanCatalog).to receive(:limit_for).and_call_original
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
    fund.update!(name: "<script>Example Fund</script>")
    institutional_rule(user:, fund:, frequency: "instant")
    _, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    expect(SendAlertJob).to have_been_enqueued.once
    delivery = AlertDelivery.sole
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(false)
    expect { SendAlertJob.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.size }
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
    2.times { SendAlertJob.perform_now(delivery.id) }
    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to eq("Reported 13F position change for #{fund.cik}")
    expect(mail.html_part.body.decoded).to include("&lt;script&gt;Example Fund&lt;/script&gt;")
    expect(mail.html_part.body.decoded).not_to include("<script>")
    expect(delivery.reload.status).to eq("sent")
  end
end
