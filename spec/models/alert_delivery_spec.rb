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
end
