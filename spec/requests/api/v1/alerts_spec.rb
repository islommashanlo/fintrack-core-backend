# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 alerts" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 10, 20)) { example.run } }
  let(:user) { create(:user, password: "password123") }

  def rule_for(owner: user, type: "Ticker", key: "ACME", active: true)
    follow = create(:follow, user: owner, target_type: type, target_key: key)
    follow.alert_rule.tap { |rule| rule.update!(active:) }
  end

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  it "requires authentication for rule, event and control routes" do
    rule = rule_for
    get api_v1_alert_rules_path
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    get api_v1_alert_events_path
    expect(response).to have_http_status(:unauthorized)
    patch api_v1_alert_rule_path(rule), params: { active: false }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(rule.reload).to be_active
  end

  it "lists only owned rules and describes existing legacy capabilities without claiming digest support" do
    rule = rule_for
    other = create(:user, email_address: "other@example.com")
    rule_for(owner: other)
    api_login(user)
    get api_v1_alert_rules_path
    expect(response).to have_http_status(:ok)
    expect(data.pluck("id")).to eq([ rule.id ])
    expect(data.sole).to include("trigger" => "new_filing", "channels" => [ "email" ], "frequency" => "instant",
      "active" => true, "conditions" => {}, "entity" => { "type" => "issuer", "key" => "ACME" })
    expect(meta.fetch("capabilities")).to include("pause_rules" => true, "resume_rules" => false,
      "daily_digest" => false, "read_tracking" => false, "rule_creation" => false)
    expect(meta.fetch("limits")).to include("alert_rules" => 3)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "pauses a rule idempotently without deleting it or delivery history" do
    rule = rule_for
    delivery = create(:alert_delivery, alert_rule: rule)
    api_login(user)
    with_api_csrf_protection do
      patch api_v1_alert_rule_path(rule), params: { active: false }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(rule.reload).to be_active
      2.times do
        expect do
          patch api_v1_alert_rule_path(rule), params: { active: false }, headers: api_headers, as: :json
        end.not_to change(AlertRule, :count)
        expect(response).to have_http_status(:ok)
        expect(data.fetch("active")).to be(false)
      end
    end
    expect(AlertDelivery.find(delivery.id)).to have_attributes(status: "pending")
    expect(SendAlertJob).not_to have_been_enqueued
  end

  it "gates all API activation of immediate email alerts on server entitlements" do
    rule = rule_for(active: false)
    api_login(user)
    patch api_v1_alert_rule_path(rule), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body).to eq("code" => "PRO_REQUIRED", "feature" => "instant_alerts", "limit" => 0)
    expect(rule.reload).not_to be_active
  end

  it "allows a server-entitled resume and checks the active-rule limit under the user's lock" do
    existing = rule_for
    paused = rule_for(key: "OTHER", active: false)
    allow(PlanCatalog).to receive(:limit_for).and_call_original
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
    allow(PlanCatalog).to receive(:limit_for).with(anything, :alert_rules).and_return(1)
    api_login(user)
    patch api_v1_alert_rule_path(paused), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body).to include("feature" => "alert_rules", "limit" => 1)
    patch api_v1_alert_rule_path(existing), params: { active: false }, headers: api_headers, as: :json
    patch api_v1_alert_rule_path(paused), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(paused.reload).to be_active
    expect(meta.dig("capabilities", "resume_rules")).to be(true)
    expect(SendAlertJob).not_to have_been_enqueued
  end

  it "returns 404 for another user's rule before any plan gate and never changes it" do
    owner = create(:user, email_address: "owner@example.com")
    rule = rule_for(owner:)
    api_login(user)
    [ true, false ].each do |active|
      patch api_v1_alert_rule_path(rule), params: { active: }, headers: api_headers, as: :json
      expect(response).to have_http_status(:not_found)
    end
    expect(rule.reload).to be_active
  end

  it "rejects unsupported settings and nonboolean activity without partial writes" do
    rule = rule_for
    api_login(user)
    [ {}, { active: "false" }, { active: 0 }, { active: nil }, { active: [ false ] },
      { active: false, frequency: "daily_digest" }, { active: false, conditions: { min_value: 1 } },
      { active: false, channels: [ "push" ] }, { active: false, user_id: user.id } ].each do |values|
      patch api_v1_alert_rule_path(rule), params: values, headers: api_headers, as: :json
      expect(response).to have_http_status(:bad_request)
      expect(rule.reload).to be_active
    end
    %w[0 invalid 9223372036854775808].each do |id|
      patch api_v1_alert_rule_path(id), params: { active: false }, headers: api_headers, as: :json
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "filters rules by active state and normalized watchlist entity types" do
    rule_for
    person = rule_for(type: "Insider", key: "0000000456", active: false)
    rule_for(type: "InstitutionalFiler", key: "0000000789")
    api_login(user)
    get api_v1_alert_rules_path, params: { active: false, entity_type: "person" }
    expect(data.pluck("id")).to eq([ person.id ])
    get api_v1_alert_rules_path, params: { entity_type: "fund" }
    expect(data.sole.dig("entity", "type")).to eq("fund")
  end

  it "returns owned delivery history with filing provenance and sanitized failure codes" do
    rule = rule_for
    sent = create(:alert_delivery, alert_rule: rule, status: "sent", delivered_at: 1.hour.ago)
    failed = create(:alert_delivery, alert_rule: rule, status: "failed", error: "provider secret abc123")
    other = create(:user, email_address: "other@example.com")
    private_delivery = create(:alert_delivery, alert_rule: rule_for(owner: other))
    api_login(user)
    get api_v1_alert_events_path
    expect(response).to have_http_status(:ok)
    expect(data.pluck("id")).to contain_exactly(sent.id, failed.id)
    expect(data.pluck("id")).not_to include(private_delivery.id)
    expect(data.find { |row| row["id"] == sent.id }).to include("accession" => sent.filing.accession_no,
      "sec_url" => sent.filing.sec_url, "filed_at" => sent.filing.filed_at.as_json, "ingested_at" => sent.filing.ingested_at.as_json,
      "data_age_days" => sent.filing.data_age_days, "status" => "sent", "error_code" => nil)
    expect(data.find { |row| row["id"] == failed.id }).to include("error_code" => "DELIVERY_FAILED")
    expect(response.body).not_to include("provider secret", "abc123", '"read_at"', '"unread"')
    expect(meta.dig("capabilities", "read_tracking")).to be(false)
  end

  it "filters delivery history by status, rule, entity and inclusive UTC creation dates" do
    rule = rule_for
    first = create(:alert_delivery, alert_rule: rule, created_at: Time.utc(2026, 11, 9), status: "failed")
    create(:alert_delivery, alert_rule: rule, created_at: Time.utc(2026, 11, 10), status: "sent")
    create(:alert_delivery, alert_rule: rule_for(type: "Insider", key: "0000000456"), status: "failed")
    api_login(user)
    get api_v1_alert_events_path, params: { status: "failed", rule_id: rule.id, entity_type: "issuer", date_from: "2026-11-09", date_to: "2026-11-09" }
    expect(data.pluck("id")).to eq([ first.id ])
    other = create(:user, email_address: "other@example.com")
    other_rule = rule_for(owner: other)
    get api_v1_alert_events_path, params: { rule_id: other_rule.id }
    expect(data).to eq([])
  end

  %w[created_at -created_at active -active entity_key -entity_key].each do |sort|
    it "paginates rules by #{sort} with ties and source ID bounds" do
      rules = 3.times.map { |i| rule_for(key: "KEY#{i}") }
      api_login(user)
      get api_v1_alert_rules_path, params: { sort:, limit: 1 }
      ids = data.pluck("id")
      cursor = meta.fetch("next_cursor")
      rule_for(key: "LATE")
      2.times do
        get api_v1_alert_rules_path, params: { sort:, limit: 1, cursor: }
        expect(response).to have_http_status(:ok)
        ids.concat(data.pluck("id"))
        cursor = meta.fetch("next_cursor")
      end
      expect(ids).to eq(sort.start_with?("-") ? rules.map(&:id).reverse : rules.map(&:id))
      expect(meta).to include("total_count" => 3, "has_more" => false, "next_cursor" => nil)
    end
  end

  %w[created_at -created_at delivered_at -delivered_at status -status].each do |sort|
    it "paginates events by #{sort} with null delivery times and late insert exclusion" do
      rule = rule_for
      deliveries = 3.times.map { create(:alert_delivery, alert_rule: rule) }
      api_login(user)
      get api_v1_alert_events_path, params: { sort:, limit: 1 }
      ids = data.pluck("id")
      cursor = meta.fetch("next_cursor")
      create(:alert_delivery, alert_rule: rule)
      2.times do
        get api_v1_alert_events_path, params: { sort:, limit: 1, cursor: }
        expect(response).to have_http_status(:ok)
        ids.concat(data.pluck("id"))
        cursor = meta.fetch("next_cursor")
      end
      expect(ids).to eq(sort.start_with?("-") ? deliveries.map(&:id).reverse : deliveries.map(&:id))
      expect(meta).to include("total_count" => 3, "has_more" => false)
    end
  end

  it "binds cursors to the owner, route, filters and expiration time" do
    2.times { |i| create(:alert_delivery, alert_rule: rule_for(key: "KEY#{i}")) }
    api_login(user)
    get api_v1_alert_rules_path, params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    get api_v1_alert_events_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
    get api_v1_alert_rules_path, params: { cursor:, active: true }
    expect(response).to have_http_status(:bad_request)
    get api_v1_alert_rules_path, params: { cursor: "#{cursor}x" }
    expect(response).to have_http_status(:bad_request)
    other = create(:user, email_address: "other@example.com", password: "password123")
    api_login(other)
    get api_v1_alert_rules_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
    api_login(user)
    travel 25.hours
    get api_v1_alert_rules_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  %w[delivered_at -delivered_at].each do |sort|
    it "keeps pending delivery timestamps after known timestamps for #{sort}" do
      rule = rule_for
      known = create(:alert_delivery, alert_rule: rule, status: "sent", delivered_at: 1.hour.ago)
      pending = create(:alert_delivery, alert_rule: rule)
      api_login(user)
      get api_v1_alert_events_path, params: { sort:, limit: 1 }
      expect(data.pluck("id")).to eq([ known.id ])
      cursor = meta.fetch("next_cursor")
      get api_v1_alert_events_path, params: { sort:, limit: 1, cursor: }
      expect(data.pluck("id")).to eq([ pending.id ])
      expect(meta.fetch("has_more")).to be(false)
    end
  end

  it "rejects invalid query filters, dates, IDs, arrays and SQL sort expressions" do
    api_login(user)
    [ { active: "yes" }, { entity_type: "unknown" }, { sort: "created_at; SELECT 1" }, { active: [ true ] }, { frequency: "instant" } ].each do |values|
      get api_v1_alert_rules_path, params: values
      expect(response).to have_http_status(:bad_request)
    end
    [ { status: "read" }, { rule_id: "9223372036854775808" }, { rule_id: "1 OR 1=1" }, { date_from: "2026-02-30" },
      { date_from: "0000-01-01" }, { date_from: "0100-02-29" }, { date_from: "2026-11-10", date_to: "2026-11-09" },
      { unread: true }, { sort: "status; SELECT 1" } ].each do |values|
      get api_v1_alert_events_path, params: values
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("INVALID_PARAMETER")
    end
  end

  it "loads filing and follow provenance with bounded page queries" do
    rule = rule_for
    4.times { create(:alert_delivery, alert_rule: rule) }
    api_login(user)
    reads = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      reads << payload[:sql] if payload[:sql].match?(/\ASELECT "(?:filings|follows|alert_rules)"\.\*/)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get api_v1_alert_events_path }
    expect(data.length).to eq(4)
    expect(reads.length).to eq(3)
  end
end
