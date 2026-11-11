# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 transaction alert rules" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }
  let(:follow) { create(:follow, user:, skip_default_alert_rule: true) }
  before { api_login(user) }

  def data = response.parsed_body.fetch("data")
  def create_rule(**attributes)
    post api_v1_alert_rules_path, params: { follow_id: follow.id, trigger: "insider_transaction", **attributes }, headers: api_headers, as: :json
  end

  it "creates a paused transaction draft alongside a separate filing rule with canonical typed conditions" do
    post api_v1_alert_rules_path, params: { follow_id: follow.id }, headers: api_headers, as: :json
    filing_rule = data.fetch("id")
    create_rule(conditions: { direction: "purchase", codes: %w[s p p], min_value: "1000.5000", role: "director" })
    expect(response).to have_http_status(:created)
    id = data.fetch("id")
    expect(id).not_to eq(filing_rule)
    expect(data).to include("trigger" => "insider_transaction", "active" => false, "frequency" => "daily_digest",
      "conditions" => { "direction" => "purchase", "codes" => %w[P S], "min_value" => "1000.5", "role" => "director" })
    create_rule
    expect(response).to have_http_status(:ok)
    expect(data.fetch("id")).to eq(id)
    expect(data.fetch("conditions").fetch("min_value")).to eq("1000.5")
    get api_v1_alert_rules_path
    expect(data.pluck("trigger")).to contain_exactly("new_filing", "insider_transaction")
    expect(response.parsed_body.dig("meta", "supported_triggers")).to include("insider_transaction")
    expect(response.parsed_body.dig("meta", "capabilities", "condition_filters")).to be(true)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    get api_v1_alert_rules_path, params: { trigger: "insider_transaction" }
    expect(data.pluck("id")).to eq([ id ])
  end

  it "validates condition shapes, currencies and enum fields before storing any rule" do
    [ { min_score: 80 }, { min_value: -1 }, { min_value: 0.1 }, { min_value: "1e3" }, { min_value: nil },
      { min_value: "1" * 31 }, { codes: "P" }, { codes: [] }, { codes: [ "P); SELECT 1" ] },
      { direction: "other_word" }, { role: "chief" }, { type: "all" }, { security_table: "all" } ].each do |conditions|
      create_rule(conditions:)
      expect(response).to have_http_status(:bad_request), conditions.inspect
    end
    expect(AlertRule.count).to eq(0)
    expect(AlertRuleSetting.count).to eq(0)
  end

  it "enforces consent, paused edits and immutable triggers without reinterpreting old event sources" do
    create_rule(conditions: { direction: "purchase" })
    id = data.fetch("id")
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    consent_email(user)
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    patch api_v1_alert_rule_path(id), params: { conditions: { direction: "sale" } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(AlertRule.find(id).setting.conditions).to eq("direction" => "purchase")
    patch api_v1_alert_rule_path(id), params: { active: false, conditions: { direction: "sale" } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(data).to include("active" => false, "conditions" => { "direction" => "sale" })
    patch api_v1_alert_rule_path(id), params: { trigger: "new_filing" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "counts both trigger types toward Free quota and retains transaction history through unfollow and deletion" do
    create_rule
    transaction_rule = AlertRule.find(data.fetch("id"))
    source = create(:filing)
    transaction = create(:insider_transaction, filing: source)
    delivery = create(:alert_delivery, alert_rule: transaction_rule, filing: source, insider_transaction: transaction, event_type: "insider_transaction")
    2.times do |index|
      target = create(:follow, user:, target_key: "OTHER#{index}", skip_default_alert_rule: true)
      post api_v1_alert_rules_path, params: { follow_id: target.id }, headers: api_headers, as: :json
      expect(response).to have_http_status(:created)
    end
    post api_v1_alert_rules_path, params: { follow_id: follow.id }, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    delete api_v1_watchlist_item_path(follow), headers: api_headers, as: :json
    expect(transaction_rule.reload).not_to be_active
    expect(transaction_rule.setting.archived_at).to be_present
    get api_v1_alert_events_path, params: { trigger: "insider_transaction" }
    expect(data.sole).to include("id" => delivery.id, "trigger" => "insider_transaction",
      "transaction" => include("id" => transaction.id, "accession" => source.accession_no))
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(AlertDelivery.exists?(delivery.id)).to be(false)
    expect(InsiderTransaction.exists?(transaction.id)).to be(true)
  end

  it "rejects fund-scoped transaction rules and keeps the paid instant gate" do
    target = create(:follow, user:, target_type: "InstitutionalFiler", target_key: "0000000123", skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: target.id, trigger: "insider_transaction" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(AlertRule.count).to eq(0)
    create_rule(frequency: "instant")
    expect(response).to have_http_status(:payment_required)
    expect(AlertRule.count).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
    expect(enqueued_jobs).to be_empty
  end
end
