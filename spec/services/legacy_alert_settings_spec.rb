# frozen_string_literal: true

require "rails_helper"

RSpec.describe LegacyAlertSettings do
  it "converts legacy settings idempotently, pauses Free instant rules and retains every delivery" do
    rule = create(:follow).alert_rule
    rule.setting.destroy!
    rule.update_columns(active: true)
    delivery = create(:alert_delivery, alert_rule: rule, status: "sent", delivered_at: 1.hour.ago, error: "retained history")
    before = delivery.attributes
    expect(described_class.counts).to eq(rules_without_settings: 1, active_free_rules: 1)
    2.times { described_class.convert! }
    expect(rule.reload).not_to be_active
    expect(rule.setting.frequency).to eq("instant")
    expect(AlertRuleSetting.count).to eq(1)
    expect(delivery.reload.attributes).to eq(before)
    expect(described_class.counts).to eq(rules_without_settings: 0, active_free_rules: 0)
  end
end
