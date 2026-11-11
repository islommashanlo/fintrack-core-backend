# frozen_string_literal: true

require "rails_helper"

RSpec.describe AlertDelivery do
  it "allows only one delivery for a rule and filing" do
    rule = create(:follow).alert_rule
    filing = create(:filing)
    create(:alert_delivery, alert_rule: rule, filing:)
    duplicate = build(:alert_delivery, alert_rule: rule, filing:)

    expect(duplicate).to be_invalid
    expect(duplicate.errors[:filing_id]).to include("has already been taken")
  end

  it "allows different transactions from one filing and enforces source-level uniqueness in Postgres" do
    follow = create(:follow, skip_default_alert_rule: true)
    rule = follow.alert_rules.create!(event_type: "insider_transaction")
    filing = create(:filing)
    first, second = 2.times.map { create(:insider_transaction, filing:) }
    deliveries = [ first, second ].map do |transaction|
      create(:alert_delivery, alert_rule: rule, filing:, insider_transaction: transaction, event_type: "insider_transaction")
    end
    expect(rule.alert_deliveries.count).to eq(2)
    duplicate = deliveries.first.dup
    expect(duplicate).not_to be_valid
    expect do
      AlertDelivery.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(rule.alert_deliveries.count).to eq(2)
  end

  it "requires a transaction source belonging to the stored filing" do
    delivery = build(:alert_delivery, event_type: "insider_transaction")
    expect(delivery).not_to be_valid
    delivery.insider_transaction = create(:insider_transaction)
    expect(delivery).not_to be_valid
    delivery.filing = delivery.insider_transaction.filing
    expect(delivery).to be_valid
  end
end
