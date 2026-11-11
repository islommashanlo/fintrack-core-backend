# frozen_string_literal: true

require "rails_helper"

RSpec.describe AlertRule do
  it "creates a paused digest draft when a legacy HTML follow is created" do
    follow = create(:follow)

    expect(follow.alert_rule).to have_attributes(event_type: "new_filing", channel: "email", active: false)
    expect(follow.alert_rule.setting.frequency).to eq("daily_digest")
  end

  it "allows a user to pause a rule" do
    rule = create(:follow).alert_rule

    rule.update!(active: false)

    expect(rule.reload).not_to be_active
  end
end
