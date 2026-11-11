# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 institutional alerts" do
  include ApiAccounts
  include InstitutionalAlertHelpers
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }
  let(:fund) { create(:institutional_filer) }
  let(:follow) { create(:follow, user:, target_type: "InstitutionalFiler", target_key: fund.cik, skip_default_alert_rule: true) }
  before { api_login(user) }

  def data = response.parsed_body.fetch("data")
  def create_rule(**values)
    post api_v1_alert_rules_path, params: { follow_id: follow.id, trigger: "13f_change", **values }, headers: api_headers, as: :json
  end

  it "creates an idempotent fund draft with canonical conditions and published capabilities" do
    create_rule(conditions: { change_types: %w[reduced added added], min_value: "100.00", direction: "increase" })
    expect(response).to have_http_status(:created)
    id = data.fetch("id")
    expect(data).to include("active" => false, "trigger" => "13f_change", "frequency" => "daily_digest",
      "conditions" => { "change_types" => %w[added reduced], "min_value" => "100.0", "direction" => "increase" })
    create_rule
    expect(data.fetch("id")).to eq(id)
    get api_v1_alert_rules_path, params: { trigger: "13f_change" }
    expect(data.pluck("id")).to eq([ id ])
    expect(response.parsed_body.dig("meta", "institutional_condition_fields")).to include("change_types", "min_value")
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "rejects malformed conditions and issuer/person scopes without partial writes" do
    [ { change_types: [] }, { change_types: [ "trim" ] }, { direction: "purchase" }, { cusip: "bad" },
      { put_call: nil }, { share_type: "OTHER" }, { min_value: 1.1 }, { min_value: "NaN" }, { ticker: "ACME" } ].each do |conditions|
      create_rule(conditions:)
      expect(response).to have_http_status(:bad_request), conditions.inspect
    end
    target = create(:follow, user:, skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: target.id, trigger: "13f_change" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(AlertRule.count).to eq(0)
  end

  it "retains consent, paused edits, immutable triggers and paid instant limits" do
    create_rule
    id = data.fetch("id")
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    consent_email(user)
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    patch api_v1_alert_rule_path(id), params: { conditions: { direction: "decrease" } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch api_v1_alert_rule_path(id), params: { active: false, conditions: { direction: "decrease" } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    patch api_v1_alert_rule_path(id), params: { trigger: "new_filing" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    create_rule(frequency: "instant")
    expect(response).to have_http_status(:payment_required)
    expect(InstitutionalChangeSnapshot.count).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "counts institutional drafts toward the shared Free rule quota" do
    create_rule
    2.times do |i|
      target = create(:follow, user:, target_key: "OTHER#{i}", skip_default_alert_rule: true)
      post api_v1_alert_rules_path, params: { follow_id: target.id }, headers: api_headers, as: :json
      expect(response).to have_http_status(:created)
    end
    post api_v1_alert_rules_path, params: { follow_id: follow.id }, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body).to include("feature" => "alert_rules", "limit" => 3)
  end

  it "batches evidence loading across comparison states" do
    consent_email(user)
    institutional_rule(user:, fund:)
    _, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    measure = lambda do
      queries = []
      callback = lambda { |*args| queries << args.last[:sql] unless args.last[:name] == "SCHEMA" || args.last[:cached] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get api_v1_alert_events_path, params: { trigger: "13f_change" } }
      expect(response).to have_http_status(:ok)
      queries.grep(/\ASELECT|\AWITH/).length
    end
    baseline = measure.call
    [ Date.new(2026, 3, 31), Date.new(2025, 12, 31) ].each_with_index do |period, index|
      report = alert_report(fund:, period:, at: (5 + index).days.ago)
      alert_holding(report, shares: 2 + index, value_reported: (2 + index) * 10, value_usd: (2 + index) * 10)
      finish_alert_report(report)
      AlertEvaluator.call(report.filing)
    end
    expect(measure.call).to be <= baseline + 1
    expect(data.length).to eq(3)
  end

  it "returns complete source evidence and retains shared snapshots when the account is removed" do
    consent_email(user)
    institutional_rule(user:, fund:)
    previous, current = alert_pair(fund:)
    AlertEvaluator.call(current.filing)
    snapshot = InstitutionalChangeSnapshot.sole
    get api_v1_alert_events_path, params: { trigger: "13f_change" }
    expect(response).to have_http_status(:ok)
    expect(data.sole).to include("transaction" => nil, "cluster" => nil, "trigger" => "13f_change")
    position = data.sole.fetch("position_change")
    expect(position).to include("change_type" => "added", "direction" => "increase", "shares_delta" => "10.0", "values_complete" => true)
    expect(position.fetch("evidence_sources").pluck("accession")).to eq([ previous.filing.accession_no, current.filing.accession_no ])
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(InstitutionalChangeSnapshot.exists?(snapshot.id)).to be(true)
    expect(AlertDelivery.count).to eq(0)
  end
end
