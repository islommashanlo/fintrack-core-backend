# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 cluster alerts" do
  include ApiAccounts
  include ClusterAlertHelpers
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }
  let(:follow) { create(:follow, user:, skip_default_alert_rule: true) }
  before { api_login(user) }

  def data = response.parsed_body.fetch("data")
  def create_rule(**attributes)
    post api_v1_alert_rules_path, params: { follow_id: follow.id, trigger: "cluster", **attributes }, headers: api_headers, as: :json
  end

  it "creates an idempotent paused draft with separate cluster conditions and metadata" do
    create_rule(conditions: { direction: "sale", min_insiders: 4, min_value: "1000.500" })
    expect(response).to have_http_status(:created)
    id = data.fetch("id")
    expect(data).to include("trigger" => "cluster", "active" => false, "frequency" => "daily_digest",
      "conditions" => { "direction" => "sale", "min_insiders" => 4, "min_value" => "1000.5" })
    create_rule
    expect(response).to have_http_status(:ok)
    expect(data.fetch("id")).to eq(id)
    expect(data.fetch("conditions").fetch("min_insiders")).to eq(4)
    get api_v1_alert_rules_path, params: { trigger: "cluster" }
    expect(data.pluck("id")).to eq([ id ])
    expect(response.parsed_body.dig("meta", "cluster_condition_fields")).to eq(%w[direction min_insiders min_value])
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "rejects unsupported directions, mutable windows, lower/noninteger thresholds and unsafe amounts" do
    [ { direction: "other" }, { direction: nil }, { window_days: 30 }, { role: "officer" }, { codes: [ "P" ] },
      { min_insiders: 2 }, { min_insiders: 1001 }, { min_insiders: "3" }, { min_insiders: 3.1 },
      { min_value: -1 }, { min_value: 1.1 }, { min_value: "1e3" }, { min_value: "NaN" } ].each do |conditions|
      create_rule(conditions:)
      expect(response).to have_http_status(:bad_request), conditions.inspect
    end
    expect(AlertRule.count).to eq(0)
    expect(InsiderClusterSnapshot.count).to eq(0)
  end

  it "retains consent, quota, pause and immutable-trigger controls without evaluating old filings" do
    create_rule
    id = data.fetch("id")
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    consent_email(user)
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    patch api_v1_alert_rule_path(id), params: { conditions: { min_insiders: 4 } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch api_v1_alert_rule_path(id), params: { active: false, conditions: { min_insiders: 4 } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    patch api_v1_alert_rule_path(id), params: { trigger: "insider_transaction" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    create_rule(frequency: "instant")
    expect(response).to have_http_status(:payment_required)
    expect(InsiderClusterSnapshot.count).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
    expect(enqueued_jobs).to be_empty
  end

  it "scopes issuer/person rules and rejects a fund or another account's follow" do
    target = create(:follow, user:, target_type: "InstitutionalFiler", target_key: "0000000123", skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: target.id, trigger: "cluster" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    other = create(:user, email_address: "cluster-other@example.com")
    target = create(:follow, user: other, skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: target.id, trigger: "cluster" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    expect(AlertRule.count).to eq(0)
  end

  it "counts all three trigger types toward the shared Free rule quota" do
    %w[new_filing insider_transaction cluster].each do |trigger|
      create_rule(trigger:)
      expect(response).to have_http_status(:created)
    end
    target = create(:follow, user:, target_key: "OTHER", skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: target.id, trigger: "cluster" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body).to include("feature" => "alert_rules", "limit" => 3)
  end

  it "batches source loading as stored windows grow and preserves each captured definition" do
    consent_email(user)
    cluster_rule(user:)
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    measure = lambda do
      queries = []
      callback = lambda { |*args| queries << args.last[:sql] unless args.last[:name] == "SCHEMA" || args.last[:cached] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get api_v1_alert_events_path, params: { trigger: "cluster" } }
      expect(response).to have_http_status(:ok)
      queries.grep(/\ASELECT|\AWITH/).length
    end
    baseline = measure.call
    3.times do |index|
      extra = cluster_trade(cik: format("%010d", 910 + index), at: (30 - index).minutes.ago)
      AlertEvaluator.call(extra.filing)
    end
    allow(ActivityMethodology).to receive(:window_days).and_return(30)
    expect(measure.call).to be <= baseline + 1
    expect(data.length).to eq(4)
    expect(data.map { |row| row.fetch("cluster").fetch("window_days") }).to all(eq(14))
  end

  it "returns immutable window evidence with batched sources and preserves shared snapshots on account deletion" do
    consent_email(user)
    rule = cluster_rule(user:)
    trades = cluster_trades
    AlertEvaluator.call(trades.last.filing)
    snapshot = InsiderClusterSnapshot.sole
    get api_v1_alert_events_path, params: { trigger: "cluster" }
    expect(response).to have_http_status(:ok)
    expect(data.sole).to include("trigger" => "cluster", "transaction" => nil, "accession" => trades.last.accession_no)
    cluster = data.sole.fetch("cluster")
    expect(cluster).to include("id" => "cluster_#{snapshot.event_key}", "insider_count" => 3, "total_value" => "600.0",
      "transaction_ids" => trades.map(&:id), "observed_at" => Time.current.as_json, "definition_minimum_insiders" => 3)
    expect(cluster.fetch("sources").pluck("accession")).to eq(trades.map(&:accession_no))
    delete api_v1_watchlist_item_path(rule.follow_id), headers: api_headers, as: :json
    expect(rule.reload).not_to be_active
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(InsiderClusterSnapshot.exists?(snapshot.id)).to be(true)
    expect(AlertDelivery.count).to eq(0)
    expect(Filing.where(id: snapshot.filing_ids).count).to eq(3)
  end
end
