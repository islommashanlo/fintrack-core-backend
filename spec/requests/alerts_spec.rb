# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Alerts" do
  let!(:user) { create(:user, email_address: "reader@example.com", password: "password123") }

  it "requires authentication" do
    get alerts_path

    expect(response).to redirect_to(new_session_path)
  end

  it "shows and pauses the user's alert rule" do
    post session_path, params: { email_address: user.email_address, password: "password123" }
    rule = create(:follow, user:, target_type: "Ticker", target_key: "ACME").alert_rule

    get alerts_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Email alerts", "ACME", "Active")

    patch alert_rule_path(rule), params: { alert_rule: { active: false } }

    expect(response).to redirect_to(alerts_path)
    expect(rule.reload).not_to be_active
  end
end
