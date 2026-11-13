# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Direct alert ownership readers" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 13, 12)) { example.run } }
  let(:user) { create(:user, password: "password123") }
  let(:other) { create(:user, email_address: "other@example.com", password: "password123") }

  def owned_rule(account, target: "ACME", channel: "email")
    follow = account.follows.find_by(target_type: "Ticker", target_key: target) ||
      create(:follow, user: account, target_key: target, skip_default_alert_rule: true)
    follow.alert_rules.create!(event_type: "new_filing", channel:)
  end

  it "keeps entity-filtered rule cursors private when accounts follow the same ticker" do
    first = owned_rule(user, target: "ACME")
    second = owned_rule(user, target: "ZETA")
    owned_rule(other)
    api_login(user)
    get api_v1_alert_rules_path, params: { entity_type: "issuer", sort: "entity_key", limit: 1 }
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.fetch("data").sole.fetch("id")).to eq(first.id)
    get api_v1_alert_rules_path, params: { entity_type: "issuer", sort: "entity_key", limit: 1, cursor: body.dig("meta", "next_cursor") }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole.fetch("id")).to eq(second.id)
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)
  end

  it "isolates event filters, summaries and read-all while retaining removed-follow history" do
    rule = owned_rule(user)
    outsider = owned_rule(other)
    delivery = create(:alert_delivery, alert_rule: rule)
    foreign_delivery = create(:alert_delivery, alert_rule: outsider)
    rule.follow.update!(removed_at: Time.current)
    api_login(user)
    get api_v1_alert_events_path, params: { entity_type: "issuer" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ delivery.id ])
    expect(AlertInboxSummary.call(user:)).to include(total_count: 1, unread_count: 1)
    expect(AlertEventReads.mark_all(user:).fetch(:updated_count)).to eq(1)
    expect(AlertInboxSummary.call(user:)).to include(total_count: 1, unread_count: 0, read_count: 1)
    expect(AlertEventState.where(alert_delivery_id: foreign_delivery.id)).not_to exist
    expect { AlertEventReads.mark(user:, id: foreign_delivery.id) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "shares channel quota slots within the owner and archives them independently" do
    email = owned_rule(user)
    in_app = owned_rule(user, channel: "in_app")
    owned_rule(other)
    expect(AlertRuleQuota.count(user)).to eq(1)
    expect(AlertRuleQuota.count(other)).to eq(1)
    AlertRuleControl.archive(user:, id: email.id)
    expect(AlertRuleQuota.count(user)).to eq(1)
    AlertRuleControl.archive(user:, id: in_app.id)
    expect(AlertRuleQuota.count(user)).to eq(0)
    expect(AlertRuleQuota.count(other)).to eq(1)
  end

  it "cleans up one account without deleting another account's same-entity rule or history" do
    rule = owned_rule(user)
    outsider = owned_rule(other)
    delivery = create(:alert_delivery, alert_rule: rule)
    foreign_delivery = create(:alert_delivery, alert_rule: outsider)
    AlertEventReads.mark(user:, id: delivery.id)
    AccountNotificationCleanup.call(user)
    user.destroy!
    expect(AlertRule.where(id: rule.id)).not_to exist
    expect(AlertDelivery.where(id: delivery.id)).not_to exist
    expect(AlertRule.find(outsider.id).user_id).to eq(other.id)
    expect(AlertDelivery.where(id: foreign_delivery.id)).to exist
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
