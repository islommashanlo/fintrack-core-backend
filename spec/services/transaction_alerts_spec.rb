# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Transaction alert matching and delivery" do
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  let(:user) { create(:user) }
  before { consent_email(user) }

  def rule(conditions: {}, type: "Ticker", key: "ACME", frequency: "daily_digest")
    follow = create(:follow, user:, target_type: type, target_key: key, followed_at: 1.year.ago, skip_default_alert_rule: true)
    result = AlertRuleControl.create(user:, follow_id: follow.id,
      attributes: { event_type: "insider_transaction", conditions: TransactionAlertConditions.normalize(conditions) })
    enable_rule(result.rule, frequency:)
  end

  def filing(**attributes)
    create(:filing, issuer_ticker: "ACME", filed_at: 1.hour.ago, **attributes)
  end

  it "matches combined filters in SQL and deduplicates joint owners by reported line, retaining qualifying owner evidence" do
    ticker = rule(conditions: { "direction" => "purchase", "codes" => [ "p" ], "type" => "open_market",
      "security_table" => "non_derivative", "role" => "officer", "min_value" => "1000" })
    person = rule(type: "Insider", key: "0000000789")
    source = filing
    first = create(:insider_transaction, filing: source, price: 20, shares: 100, is_officer: true)
    joint = create(:insider_transaction, filing: source, owner_seq: 2, insider_cik: "0000000789", txn_seq: first.txn_seq,
      is_officer: true, price: 20, shares: 100)
    second = create(:insider_transaction, filing: source, price: 20, shares: 100, is_officer: true)
    create(:insider_transaction, filing: source, transaction_code: "S", is_officer: true)
    create(:insider_transaction, filing: source, price: 1, is_officer: true)
    create(:insider_transaction, filing: source, security_table: "derivative", is_officer: true)
    expect { AlertEvaluator.call(source) }.to change(AlertDelivery, :count).by(3)
    expect(ticker.alert_deliveries.pluck(:insider_transaction_id)).to contain_exactly(first.id, second.id)
    expect(person.alert_deliveries.pluck(:insider_transaction_id)).to eq([ joint.id ])
    expect(ticker.alert_deliveries.pluck(:rule_revision)).to all(eq(ticker.setting.revision))
    expect { AlertEvaluator.call(source) }.not_to change(AlertDelivery, :count)
    expect(SendAlertJob).not_to have_been_enqueued
  end

  it "selects a later reporting owner when that owner alone satisfies a role condition" do
    target = rule(conditions: { "role" => "director" })
    source = filing
    first = create(:insider_transaction, filing: source)
    joint = create(:insider_transaction, filing: source, insider_cik: "0000000789", owner_seq: 2,
      txn_seq: first.txn_seq, is_director: true)
    AlertEvaluator.call(source)
    expect(target.alert_deliveries.sole.insider_transaction_id).to eq(joint.id)
  end

  it "never treats suspect or missing prices as known zero-dollar values" do
    valued = rule(conditions: { "min_value" => 0 })
    unfiltered = rule(type: "Insider", key: "0000000456")
    source = filing
    create(:insider_transaction, filing: source, price: nil)
    create(:insider_transaction, filing: source, price_suspect: true)
    zero = create(:insider_transaction, filing: source, price: 0)
    AlertEvaluator.call(source)
    expect(valued.alert_deliveries.pluck(:insider_transaction_id)).to eq([ zero.id ])
    expect(unfiltered.alert_deliveries.count).to eq(3)
  end

  it "matches administrative, derivative and other-direction rows without guessing a missing transaction code" do
    target = rule(conditions: { "type" => "administrative", "direction" => "other", "security_table" => "derivative" })
    source = filing
    gift = create(:insider_transaction, filing: source, transaction_code: "G", security_table: "derivative")
    unknown = create(:insider_transaction, filing: source, transaction_code: nil, security_table: "derivative")
    create(:insider_transaction, filing: source, security_table: "derivative")
    create(:insider_transaction, filing: source, transaction_code: "G")
    AlertEvaluator.call(source)
    expect(target.alert_deliveries.pluck(:insider_transaction_id)).to contain_exactly(gift.id, unknown.id)
    expect(TransactionAlertText.render(unknown)).to include("transaction code not provided")
  end

  it "excludes future/failed filings and removed, paused or archived rules" do
    target = rule
    [ filing(filed_at: 1.day.from_now), filing(parse_status: "failed"), filing(form_type: "8-K") ].each do |source|
      create(:insider_transaction, filing: source)
      expect { AlertEvaluator.call(source) }.not_to change(AlertDelivery, :count)
    end
    source = filing
    create(:insider_transaction, filing: source)
    target.update!(active: false)
    expect { AlertEvaluator.call(source) }.not_to change(AlertDelivery, :count)
    target.update!(active: true)
    target.setting.update!(enabled_at: 1.year.ago)
    WatchlistMembership.remove(user:, id: target.follow_id)
    expect { AlertEvaluator.call(source) }.not_to change(AlertDelivery, :count)
  end

  it "never replays transactions filed before the current follow or rule activation" do
    target = rule
    source = filing
    create(:insider_transaction, filing: source)
    target.setting.update!(enabled_at: Time.current)
    expect { AlertEvaluator.call(source) }.not_to change(AlertDelivery, :count)
    target.setting.update!(enabled_at: 1.year.ago)
    target.follow.update!(followed_at: Time.current)
    expect { AlertEvaluator.call(source) }.not_to change(AlertDelivery, :count)
  end

  it "preserves old deliveries while matching amendments and suppressing superseded queued transactions" do
    target = rule
    original = filing
    create(:insider_transaction, filing: original)
    AlertEvaluator.call(original)
    old = target.alert_deliveries.sole
    amendment = filing(form_type: "4/A", amends_accession_no: original.accession_no, filed_at: 1.minute.ago)
    corrected = create(:insider_transaction, filing: amendment, shares: 75)
    expect { AlertEvaluator.call(original) }.not_to change(AlertDelivery, :count)
    AlertEvaluator.call(amendment)
    expect(target.alert_deliveries.pluck(:insider_transaction_id)).to include(corrected.id)
    expect(AlertDeliveryPolicy.eligible?(old, user:, frequency: "daily_digest")).to be(false)
    expect(old.reload.status).to eq("pending")
  end

  it "invalidates queued matches on condition changes even when timestamps are identical" do
    target = rule(conditions: { "direction" => "purchase" })
    source = filing
    create(:insider_transaction, filing: source)
    AlertEvaluator.call(source)
    delivery = target.alert_deliveries.sole
    original_revision = delivery.rule_revision
    AlertRuleControl.update(user:, id: target.id, attributes: { active: false, conditions: { "direction" => "sale" } })
    AlertRuleControl.update(user:, id: target.id, attributes: { active: true })
    expect(target.setting.reload.revision).to eq(original_revision + 1)
    expect(AlertDeliveryPolicy.eligible?(delivery, user:, frequency: "daily_digest")).to be(false)
    travel 1.day
    expect(AlertDigestPlanner.call(user:)).to be_nil
    expect(delivery.reload.event_type).to eq("insider_transaction")
  end

  it "includes factual transaction details in Free daily digests and preserves source/unsubscribe headers" do
    rule
    source = filing
    transaction = create(:insider_transaction, filing: source, shares: BigDecimal("12.5"), price: BigDecimal("20.25"))
    AlertEvaluator.call(source)
    travel 1.day
    batch = AlertDigestPlanner.call(user:)
    expect { SendAlertDigestJob.perform_now(batch.id) }.to change { ActionMailer::Base.deliveries.size }.by(1)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.text_part.body.decoded).to include("open-market purchase of 12.5", "$253.125", transaction.insider_name, source.accession_no)
    expect(mail["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
    expect(AlertDelivery.sole.status).to eq("sent")
  end

  it "enqueues one paid instant email per line, escapes reported text and stays idempotent" do
    allow(PlanCatalog).to receive(:limit_for).and_call_original
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
    target = rule(frequency: "instant")
    source = filing
    create(:insider_transaction, filing: source, insider_name: "<script>Example</script>")
    AlertEvaluator.call(source)
    expect(SendAlertJob).to have_been_enqueued.once
    delivery = target.alert_deliveries.sole
    2.times { SendAlertJob.perform_now(delivery.id) }
    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to eq("Reported insider transaction for ACME")
    expect(mail.html_part.body.decoded).to include("&lt;script&gt;Example&lt;/script&gt;")
    expect(mail.html_part.body.decoded).not_to include("<script>")
    expect(delivery.reload.status).to eq("sent")
  end

  it "retains queued instant history without sending after paid access is removed" do
    allow(PlanCatalog).to receive(:limit_for).and_call_original
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
    target = rule(frequency: "instant")
    source = filing
    create(:insider_transaction, filing: source)
    AlertEvaluator.call(source)
    delivery = target.alert_deliveries.sole
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(false)
    expect { SendAlertJob.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.size }
    expect(delivery.reload.status).to eq("pending")
  end
end
