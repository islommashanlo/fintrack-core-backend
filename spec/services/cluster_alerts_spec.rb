# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cluster alert matching and delivery" do
  include ClusterAlertHelpers
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  let(:user) { create(:user) }
  before { consent_email(user) }

  it "stores the same cluster as the read API, shares snapshots across matching rules and deduplicates retries" do
    first = cluster_rule(user:)
    second = cluster_rule(user:, type: "Insider", key: "0000000999")
    trades = cluster_trades
    create(:insider_transaction, filing: trades.first.filing, insider_cik: "0000000999", owner_seq: 2, txn_seq: trades.first.txn_seq)
    expect { AlertEvaluator.call(trades.last.filing) }.to change(AlertDelivery, :count).by(2)
    snapshot = InsiderClusterSnapshot.sole
    expect(snapshot).to have_attributes(insider_count: 3, transaction_count: 3, total_value: 600.to_d,
      transaction_ids: trades.map(&:id), filing_ids: trades.map(&:filing_id), observed_at: Time.current)
    expect([ first, second ].map { |rule| rule.alert_deliveries.sole.insider_cluster_snapshot_id }).to eq([ snapshot.id, snapshot.id ])
    page = Api::V1::CursorPage.new(parameters: {}, context: { "test" => "clusters" }, sorts: Api::V1::InsiderClustersQuery::SORTS,
      default_sort: "-window_end", bounds: Api::V1::InsiderClustersQuery::BOUNDS)
    result = Api::V1::InsiderClustersQuery.new(page:, filters: Api::V1::InsiderClustersParameters.normalize({})).call
    expect(result.records.sole.fetch("event_key")).to eq(snapshot.event_key)
    expect { AlertEvaluator.call(trades.last.filing) }.not_to change(AlertDelivery, :count)
    expect(InsiderClusterSnapshot.count).to eq(1)
    expect(SendAlertJob).not_to have_been_enqueued
    expect { snapshot.update!(insider_count: 999) }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "requires distinct first-listed insiders and excludes administrative, derivative and unrelated issuer rows" do
    cluster_rule(user:)
    first = cluster_trade(cik: "0000000901")
    2.times { |i| cluster_trade(cik: format("%010d", 902 + i), filing: first.filing, owner_seq: i + 2, txn_seq: first.txn_seq) }
    cluster_trade(cik: "0000000901")
    cluster_trade(cik: "0000000902", code: "A")
    cluster_trade(cik: "0000000902", security_table: "derivative")
    cluster_trade(cik: "0000000902", issuer: "0000000999")
    expect { AlertEvaluator.call(first.filing) }.not_to change(AlertDelivery, :count)
    cluster_trade(cik: "0000000902")
    last = cluster_trade(cik: "0000000903")
    AlertEvaluator.call(last.filing)
    expect(InsiderClusterSnapshot.sole).to have_attributes(insider_count: 3, transaction_count: 4, total_value: 800.to_d)
  end

  it "uses the exclusive 14-day start, acceptance rather than trade dates, and permits prior activation context" do
    rule = cluster_rule(user:)
    rule.setting.update!(enabled_at: 2.hours.ago)
    ending = 1.hour.ago
    cluster_trade(cik: "0000000901", at: ending - 14.days)
    cluster_trade(cik: "0000000902", at: ending - 7.days, transaction_date: 2.years.ago.to_date)
    last = cluster_trade(cik: "0000000903", at: ending, transaction_date: 2.years.ago.to_date)
    expect { AlertEvaluator.call(last.filing) }.not_to change(AlertDelivery, :count)
    included = cluster_trade(cik: "0000000904", at: ending - 14.days + 1.second)
    AlertEvaluator.call(last.filing)
    expect(InsiderClusterSnapshot.sole.transaction_ids).to contain_exactly(included.id, last.id, InsiderTransaction.find_by!(insider_cik: "0000000902").id)
  end

  it "keeps unknown totals unknown and applies direction, minimum count and complete-value conditions" do
    all = cluster_rule(user:)
    valued = cluster_rule(user:, type: "Insider", key: "0000000901", conditions: { "min_value" => "0" })
    larger = cluster_rule(user:, type: "Insider", key: "0000000902", conditions: { "min_insiders" => 4 })
    trades = cluster_trades
    trades.first.update!(price_suspect: true)
    trades.second.update!(price: nil)
    AlertEvaluator.call(trades.last.filing)
    expect(all.alert_deliveries.count).to eq(1)
    expect(valued.alert_deliveries.count).to eq(0)
    expect(larger.alert_deliveries.count).to eq(0)
    expect(InsiderClusterSnapshot.sole).to have_attributes(total_value: nil, known_value_subtotal: 200.to_d, transactions_without_usable_price: 2)
  end

  it "mirrors sale clusters independently and never combines directions" do
    rule = cluster_rule(user:, conditions: { "direction" => "sale", "min_value" => "600.0" })
    purchases, sales = cluster_trades, cluster_trades(code: "S")
    expect { AlertEvaluator.call(purchases.last.filing) }.not_to change(AlertDelivery, :count)
    AlertEvaluator.call(sales.last.filing)
    expect(rule.alert_deliveries.sole.insider_cluster_snapshot).to have_attributes(transaction_code: "S", total_value: 600.to_d)
  end

  it "discovers a later window completed by a delayed earlier filing while excluding future and failed filings" do
    rule = cluster_rule(user:)
    latest = cluster_trade(cik: "0000000903", at: 1.hour.ago)
    middle = cluster_trade(cik: "0000000902", at: 2.hours.ago)
    cluster_trade(cik: "0000000904", at: 1.day.from_now)
    failed = cluster_trade(cik: "0000000905")
    failed.filing.update!(parse_status: "failed")
    expect { AlertEvaluator.call(latest.filing) }.not_to change(AlertDelivery, :count)
    delayed = cluster_trade(cik: "0000000901", at: 3.hours.ago)
    AlertEvaluator.call(delayed.filing)
    delivery = rule.alert_deliveries.sole
    expect(delivery.filing_id).to eq(latest.filing_id)
    expect(delivery.insider_cluster_snapshot.transaction_ids).to contain_exactly(delayed.id, middle.id, latest.id)
  end

  it "preserves previous window states when late membership changes and emits separate rolling windows" do
    rule = cluster_rule(user:)
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    old = InsiderClusterSnapshot.sole
    late = cluster_trade(cik: "0000000904", at: 2.hours.ago + 1.minute)
    AlertEvaluator.call(late.filing)
    current = cluster_trade(cik: "0000000905", at: 1.minute.ago)
    AlertEvaluator.call(current.filing)
    expect(rule.alert_deliveries.count).to eq(4)
    expect(old.reload.transaction_ids).to eq(trades.map(&:id))
    expect(InsiderClusterSnapshot.where(window_end: trades.last.filing.filed_at).count).to eq(2)
  end

  it "suppresses queued mail when any constituent is superseded and retains old source history" do
    cluster_rule(user:)
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    delivery = AlertDelivery.sole
    amendment = create(:filing, form_type: "4/A", issuer_ticker: "ACME", filed_at: 1.minute.ago, amends_accession_no: trades.first.accession_no)
    create(:insider_transaction, filing: amendment, insider_cik: trades.first.insider_cik, transaction_code: "S")
    expect(AlertDeliveryPolicy.eligible?(delivery, user:, frequency: "daily_digest")).to be(false)
    travel 1.day
    expect(AlertDigestPlanner.call(user:)).to be_nil
    expect(delivery.reload.status).to eq("pending")
    expect(delivery.insider_cluster_snapshot.transaction_ids).to include(trades.first.id)
  end

  it "skips pre-activation sources, changed configurations, paused rules and removed follows" do
    rule = cluster_rule(user:)
    trades = cluster_trades
    rule.setting.update!(enabled_at: Time.current)
    expect { AlertEvaluator.call(trades.last.filing) }.not_to change(AlertDelivery, :count)
    rule.setting.update!(enabled_at: 1.year.ago)
    AlertEvaluator.call(trades.last.filing)
    delivery = AlertDelivery.sole
    AlertRuleControl.update(user:, id: rule.id, attributes: { active: false, conditions: { "direction" => "sale" } })
    AlertRuleControl.update(user:, id: rule.id, attributes: { active: true })
    expect(AlertDeliveryPolicy.eligible?(delivery, user:, frequency: "daily_digest")).to be(false)
    WatchlistMembership.remove(user:, id: rule.follow_id)
    expect { AlertEvaluator.call(trades.last.filing) }.not_to change(AlertDelivery, :count)
  end

  it "sends factual Free digest copy with all constituent sources through the test adapter" do
    cluster_rule(user:)
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    travel 1.day
    batch = AlertDigestPlanner.call(user:)
    SendAlertDigestJob.perform_now(batch.id)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.text_part.body.decoded).to include("3 first-listed insiders", "14-day window", "$600.0", *trades.map { |t| t.filing.sec_url })
    expect(mail["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
    expect(AlertDelivery.sole.status).to eq("sent")
  end

  it "rechecks paid access for instant cluster email and sends only once when eligible" do
    allow(PlanCatalog).to receive(:limit_for).and_call_original
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
    cluster_rule(user:, type: "Insider", key: "0000000901", frequency: "instant")
    trades = cluster_trades
    trades.last.update!(issuer_ticker: "<script>ACME</script>")
    AlertEvaluator.call(trades.last.filing)
    expect(SendAlertJob).to have_been_enqueued.once
    delivery = AlertDelivery.sole
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(false)
    expect { SendAlertJob.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.size }
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
    2.times { SendAlertJob.perform_now(delivery.id) }
    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to eq("Reported insider cluster for 0000000901")
    expect(mail.html_part.body.decoded).to include("&lt;script&gt;ACME&lt;/script&gt;")
    expect(mail.html_part.body.decoded).not_to include("<script>")
    expect(delivery.reload.status).to eq("sent")
  end
end
