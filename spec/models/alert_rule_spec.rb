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

  it "persists the follow owner for default and explicitly created channel rules" do
    follow = create(:follow)
    expect(follow.alert_rule.reload.user_id).to eq(follow.user_id)
    rule = follow.alert_rules.create!(channel: "in_app", event_type: "new_filing")
    expect(rule.reload.user).to eq(follow.user)
    expect(follow.user.alert_rules).to contain_exactly(follow.alert_rule, rule)
  end

  it "rejects cross-account owners and prevents implicit transfers on follow changes" do
    follow = create(:follow)
    other = create(:user, email_address: "other@example.com")
    rule = follow.alert_rule
    rule.user = other
    expect(rule).not_to be_valid
    expect(rule.errors[:user]).to include("must own the watchlist item")
    rule.reload
    other_follow = create(:follow, user: other, target_key: "OTHER", skip_default_alert_rule: true)
    rule.follow = other_follow
    expect(rule).not_to be_valid
    expect(rule.user_id).to eq(follow.user_id)
  end

  it "enforces ownership and presence when validation and callbacks are bypassed" do
    rule = create(:follow).alert_rule
    other = create(:user, email_address: "other@example.com")
    expect do
      ApplicationRecord.transaction(requires_new: true) { rule.update_columns(user_id: other.id) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    expect do
      ApplicationRecord.transaction(requires_new: true) { rule.update_columns(user_id: nil) }
    end.to raise_error(ActiveRecord::NotNullViolation)
    expect(rule.reload.user_id).to eq(rule.follow.user_id)
    expect do
      ApplicationRecord.transaction(requires_new: true) { rule.follow.update_columns(user_id: other.id) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
