# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Watchlist alert drafts" do
  include ApiAccounts
  include OpenapiResponses
  around { |example| with_api_csrf_protection { example.run } }
  let(:user) { create(:user, password: "password123") }
  before { api_login(user) }

  def create_draft(**attributes)
    post api_v1_alert_rules_path, params: { scope: "watchlist", **attributes }, headers: api_headers, as: :json
  end

  it "creates an owned paused draft without a follow and round-trips scope metadata" do
    expect { create_draft(channels: [ "in_app" ]) }.to change(AlertRule, :count).by(1).and change(Follow, :count).by(0)
    expect(response).to have_http_status(:created)
    expect_documented_response(path: "/alert-rules", method: :post)
    expect(response.parsed_body.fetch("data")).to include("scope" => "watchlist", "follow_id" => nil,
      "entity" => { "type" => "watchlist", "key" => nil }, "active" => false, "frequency" => "daily_digest")
    expect(AlertRule.sole.user_id).to eq(user.id)
    expect(response.parsed_body.fetch("meta")).to include("supported_scopes" => %w[follow watchlist], "watchlist_activation" => true)
    create_draft(channels: [ "in_app" ])
    expect(response).to have_http_status(:ok)
    expect(AlertRule.count).to eq(1)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "counts watchlist triggers once across channels alongside specific rules" do
    create_draft
    create_draft(channels: [ "in_app" ])
    create_draft(trigger: "insider_transaction", conditions: { direction: "purchase" })
    create_draft(trigger: "13f_change", conditions: { change_types: [ "new" ] })
    expect(AlertRuleQuota.count(user)).to eq(3)
    create_draft(trigger: "news")
    expect(response).to have_http_status(:payment_required)
    expect(AlertRule.count).to eq(4)
    create_draft(channels: [ "in_app" ])
    expect(response).to have_http_status(:ok)
  end

  it "keeps watchlist email activation blocked through create, update, model and direct writes" do
    expect { create_draft(active: true) }.not_to change(AlertRule, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    create_draft
    rule = AlertRule.sole
    patch api_v1_alert_rule_path(rule), params: { active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(rule.reload).not_to be_active
    rule.active = true
    expect(rule).not_to be_valid
    expect do
      ApplicationRecord.transaction(requires_new: true) { rule.update_columns(active: true) }
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect(rule.reload).not_to be_active
  end

  it "filters scope and entity types and paginates nullable entity keys without leaking accounts" do
    follow = create(:follow, user:, skip_default_alert_rule: true)
    specific = AlertRuleControl.create(user:, follow_id: follow.id, attributes: {}).rule
    create_draft
    draft = AlertRule.find_by!(scope: "watchlist")
    other = create(:user, email_address: "other@example.com")
    other.alert_rules.create!(scope: "watchlist", event_type: "new_filing")
    get api_v1_alert_rules_path, params: { sort: "entity_key", limit: 1 }
    expect(response.parsed_body.fetch("data").sole.fetch("id")).to eq(specific.id)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    get api_v1_alert_rules_path, params: { sort: "entity_key", limit: 1, cursor: }
    expect(response.parsed_body.fetch("data").sole.fetch("id")).to eq(draft.id)
    expect_documented_response(path: "/alert-rules", method: :get)
    get api_v1_alert_rules_path, params: { scope: "watchlist" }
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ draft.id ])
    get api_v1_alert_rules_path, params: { entity_type: "issuer" }
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ specific.id ])
    get api_v1_alert_rules_path, params: { scope: "watchlist", entity_type: "issuer" }
    expect(response.parsed_body.fetch("data")).to eq([])
  end

  it "rejects mixed targets, invalid scopes, scope mutation and client ownership" do
    [ { follow_id: 1 }, { follow_id: nil }, { scope: "global" }, { scope: [] }, { user_id: user.id } ].each do |attributes|
      expect { create_draft(**attributes) }.not_to change(AlertRule, :count)
      expect(response).to have_http_status(:bad_request)
    end
    create_draft
    rule = AlertRule.sole
    patch api_v1_alert_rule_path(rule), params: { scope: "follow" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(rule.reload.scope).to eq("watchlist")
    get api_v1_alert_rules_path, params: { scope: "global" }
    expect(response).to have_http_status(:bad_request)
  end

  it "archives and restores channel drafts with shared quota and ownership checks" do
    create_draft
    rule = AlertRule.sole
    delete api_v1_alert_rule_path(rule), headers: api_headers
    expect(response).to have_http_status(:no_content)
    expect(AlertRuleQuota.count(user)).to eq(0)
    create_draft
    expect(response).to have_http_status(:created)
    expect(AlertRule.count).to eq(1)
    expect(AlertRuleQuota.count(user)).to eq(1)
    expect(rule.reload).not_to be_active
    get alerts_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("All watched entities")
    AccountNotificationCleanup.call(user)
    user.destroy!
    expect(AlertRule.where(id: rule.id)).not_to exist
  end
  it "supports every existing trigger as a draft and isolates edits from other owners" do
    AlertRule::EVENT_TYPES.each do |trigger|
      create_draft(trigger:)
      expect(response).to have_http_status(:created)
      id = response.parsed_body.dig("data", "id")
      expect(AlertRule.find(id)).not_to be_active
      delete api_v1_alert_rule_path(id), headers: api_headers
    end
    other = create(:user, email_address: "other@example.com")
    foreign = other.alert_rules.create!(scope: "watchlist", event_type: "news")
    patch api_v1_alert_rule_path(foreign), params: { active: false }, headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    delete api_v1_alert_rule_path(foreign), headers: api_headers
    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.setting.archived_at).to be_nil
  end

  it "edits draft conditions with a revision, rejects Free instant timing and survives unfollow" do
    create_draft(trigger: "insider_transaction")
    rule = AlertRule.sole
    revision = rule.setting.revision
    patch api_v1_alert_rule_path(rule), params: { conditions: { min_value: "123.45" } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(rule.setting.reload).to have_attributes(conditions: { "min_value" => "123.45" }, revision: revision + 1)
    patch api_v1_alert_rule_path(rule), params: { frequency: "instant" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    expect(rule.setting.reload.frequency).to eq("daily_digest")
    follow = create(:follow, user:, skip_default_alert_rule: true)
    WatchlistMembership.remove(user:, id: follow.id)
    expect(rule.reload.setting.archived_at).to be_nil
    expect(AlertRuleQuota.count(user)).to eq(1)
  end

  it "enforces scope shapes and watchlist uniqueness even without callbacks" do
    create_draft
    rule = AlertRule.sole
    expect do
      ApplicationRecord.transaction(requires_new: true) { rule.update_columns(scope: "follow") }
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect do
      ApplicationRecord.transaction(requires_new: true) do
        AlertRule.insert_all!([ { user_id: user.id, scope: "watchlist", event_type: "new_filing", channel: "email" } ])
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(rule.reload.scope).to eq("watchlist")
  end
  it "requires a fresh rule cursor after the scope-aware list version change" do
    create_draft
    create_draft(trigger: "news")
    get api_v1_alert_rules_path, params: { limit: 1 }
    verifier = Rails.application.message_verifier("api.v1.read_pages")
    payload = verifier.verify(response.parsed_body.dig("meta", "next_cursor"), purpose: "pagination")
    expect(payload.fetch("context").fetch("version")).to eq(2)
    payload.fetch("context").delete("version")
    old = verifier.generate(payload, purpose: "pagination", expires_in: 24.hours)
    get api_v1_alert_rules_path, params: { limit: 1, cursor: old }
    expect(response).to have_http_status(:bad_request)
  end
end
