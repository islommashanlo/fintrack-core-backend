# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 news alert rules and history" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }
  let(:fund) { news_entity(role: "fund") }
  let(:follow) { create(:follow, user:, target_type: "InstitutionalFiler", target_key: InstitutionalFiler.find(fund.id).cik, skip_default_alert_rule: true) }
  before do
    approve_fixture_news
    api_login(user)
  end

  def data = response.parsed_body.fetch("data")
  def create_rule(**attributes)
    post api_v1_alert_rules_path, params: { follow_id: follow.id, trigger: "news", **attributes }, headers: api_headers, as: :json
  end

  it "creates idempotent drafts, canonicalizes news-only filters and advertises capabilities" do
    create_rule(conditions: { kinds: %w[press_release news news], providers: %w[fixture fixture], source: "Example Newsroom" })
    expect(response).to have_http_status(:created)
    id = data.fetch("id")
    expect(data).to include("trigger" => "news", "active" => false, "frequency" => "daily_digest",
      "conditions" => { "kinds" => %w[news press_release], "providers" => [ "fixture" ], "source" => "Example Newsroom" })
    create_rule
    expect(data.fetch("id")).to eq(id)
    get api_v1_alert_rules_path, params: { trigger: "news" }
    expect(data.pluck("id")).to eq([ id ])
    expect(response.parsed_body.dig("meta", "news_condition_fields")).to eq(%w[kinds source providers])
  end

  it "rejects unsupported conditions and retains consent, paused edits, immutable triggers and Free instant gating" do
    [ { kinds: [] }, { kinds: [ "prediction" ] }, { providers: [ "../invalid" ] }, { source: " " },
      { source: "<b>Example</b>" }, { min_value: "100" }, { direction: "purchase" } ].each do |conditions|
      create_rule(conditions:)
      expect(response).to have_http_status(:bad_request)
    end
    create_rule
    id = data.fetch("id")
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    consent_email(user)
    patch api_v1_alert_rule_path(id), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    patch api_v1_alert_rule_path(id), params: { conditions: { kinds: [ "other" ] } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch api_v1_alert_rule_path(id), params: { trigger: "new_filing" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch api_v1_alert_rule_path(id), params: { active: false }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    create_rule(frequency: "instant")
    expect(response).to have_http_status(:payment_required)
  end

  it "returns news evidence with null SEC provenance and redacts source copy when publication is revoked" do
    consent_email(user)
    rule = news_rule(user:, entity: fund)
    item = store_news(entities: [ fund ])
    NewsAlertEvaluator.call(item)
    get api_v1_alert_events_path, params: { trigger: "news" }
    expect(response).to have_http_status(:ok)
    expect(data.sole).to include("trigger" => "news", "accession" => nil, "sec_url" => nil, "filed_at" => nil, "news_available" => true)
    expect(data.sole.fetch("news")).to include("title" => item.title, "url" => item.url, "news_item_id" => item.id)
    post api_v1_alert_event_read_path(data.sole.fetch("id")), headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    patch api_v1_alert_rule_path(rule.id), params: { active: false }, headers: api_headers, as: :json
    get api_v1_alert_events_path, params: { trigger: "news" }
    expect(data.sole.fetch("news_available")).to be(true)
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("")
    get api_v1_alert_events_path, params: { trigger: "news" }
    expect(data.sole).to include("news" => nil, "news_available" => false)
    expect(response.body).not_to include(item.title, item.url)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "batches history source checks and renders the legacy history without a filing" do
    consent_email(user)
    news_rule(user:, entity: fund)
    NewsAlertEvaluator.call(store_news(entities: [ fund ]))
    measure = lambda do
      queries = []
      callback = ->(*args) { queries << args.last[:sql] unless args.last[:name] == "SCHEMA" || args.last[:cached] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get api_v1_alert_events_path, params: { trigger: "news" } }
      expect(response).to have_http_status(:ok)
      queries.grep(/\ASELECT|\AWITH/).length
    end
    first = measure.call
    2.times { NewsAlertEvaluator.call(store_news(entities: [ fund ])) }
    expect(measure.call).to be <= first + 1
    expect(data.length).to eq(3)
    get alerts_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(NewsItem.first.title)
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("")
    get alerts_path
    expect(response.body).to include("News source unavailable")
    expect(response.body).not_to include(NewsItem.first.title)
  end

  it "retains immutable shared evidence after account deletion" do
    consent_email(user)
    news_rule(user:, entity: fund)
    NewsAlertEvaluator.call(store_news(entities: [ fund ]))
    snapshot = NewsAlertSnapshot.sole
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(AlertDelivery.count).to eq(0)
    expect(NewsAlertSnapshot.exists?(snapshot.id)).to be(true)
  end
end
