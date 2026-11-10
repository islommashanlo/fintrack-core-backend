# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 watchlist" do
  include ApiAccounts
  around { |example| with_api_csrf_protection { example.run } }
  let(:user) { create(:user, password: "password123") }

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  def add_target(type, key)
    post api_v1_watchlist_path, params: { entity_type: type, entity_key: key }, headers: api_headers, as: :json
  end

  it "requires authentication and returns JSON rather than a login redirect" do
    get api_v1_watchlist_path
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("UNAUTHENTICATED")
  end

  it "adds issuer, fund and person targets and keeps watchlist membership separate from email alerts" do
    filing = create(:filing, issuer_ticker: "ACME", issuer_name: "Example Company", owner_ciks: [ "0000000456" ])
    create(:filer, cik: "0000000456", name: "Jane Example")
    fund = create(:institutional_filer)
    api_login(user)

    expect do
      add_target("issuer", "acme")
      expect(response).to have_http_status(:created)
      expect(data).to include("entity_type" => "issuer", "entity_key" => "ACME", "name" => filing.issuer_name)
      add_target("fund", fund.cik)
      expect(response).to have_http_status(:created)
      add_target("person", "0000000456")
      expect(response).to have_http_status(:created)
    end.to change(Follow, :count).by(3).and change(AlertRule, :count).by(0)
    expect(SendAlertJob).not_to have_been_enqueued

    get api_v1_watchlist_path
    expect(data.pluck("entity_type")).to contain_exactly("issuer", "fund", "person")
    expect(data.pluck("name")).to contain_exactly("Example Company", fund.name, "Jane Example")
    expect(meta.fetch("total_count")).to eq(3)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(data.first.keys).to contain_exactly("id", "entity_type", "entity_key", "name", "created_at")
  end

  it "uses exact issuer matching and existing mappings without guessing from a similar ticker" do
    create(:filing, issuer_ticker: "ACME.A")
    api_login(user)
    add_target("issuer", "ACME")
    expect(response).to have_http_status(:not_found)
    expect(user.follows.count).to eq(0)
  end

  it "does not expose or delete another user's private watchlist" do
    other = create(:user, email_address: "other@example.com", password: "password123")
    other_follow = create(:follow, user: other)
    mine = create(:follow, user:)
    api_login(user)
    get api_v1_watchlist_path
    expect(data.pluck("id")).to eq([ mine.id ])
    delete api_v1_watchlist_item_path(other_follow.id), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    expect(Follow.exists?(other_follow.id)).to be(true)
  end

  it "paginates memberships without admitting late inserts and binds cursors to the authenticated user" do
    first = create(:follow, user:, target_key: "FIRST")
    second = create(:follow, user:, target_key: "SECOND")
    api_login(user)
    get api_v1_watchlist_path, params: { limit: 1 }
    expect(data.pluck("id")).to eq([ second.id ])
    cursor = meta.fetch("next_cursor")
    create(:follow, user:, target_key: "LATER")
    get api_v1_watchlist_path, params: { limit: 1, cursor: }
    expect(data.pluck("id")).to eq([ first.id ])
    expect(meta).to include("total_count" => 2, "has_more" => false)

    other = create(:user, email_address: "other@example.com", password: "password123")
    api_login(other)
    get api_v1_watchlist_path, params: { limit: 1, cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "enforces the Free limit atomically while keeping duplicate adds idempotent at the limit" do
    filing = create(:filing, issuer_ticker: "ACME")
    api_login(user)
    14.times { |i| create(:follow, user:, target_key: "EXAMPLE#{i}", skip_default_alert_rule: true) }
    add_target("issuer", "ACME")
    expect(response).to have_http_status(:created)
    follow_id = data.fetch("id")
    add_target("issuer", "acme")
    expect(response).to have_http_status(:ok)
    expect(data.fetch("id")).to eq(follow_id)
    create(:filing, issuer_ticker: "NEXT")

    expect { add_target("issuer", "NEXT") }.not_to change(Follow, :count)
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body).to eq("code" => "PRO_REQUIRED", "feature" => "watchlist_items", "limit" => 15)
    expect(Filing.exists?(filing.id)).to be(true)
  end

  it "applies the same membership limit through the existing HTML follow endpoint" do
    create(:filing, issuer_ticker: "ACME")
    create(:insider_transaction, filing: Filing.last)
    15.times { |i| create(:follow, user:, target_key: "EXAMPLE#{i}", skip_default_alert_rule: true) }
    api_login(user)
    expect do
      post follows_path, params: { follow: { target_type: "Ticker", target_key: "ACME" } }
    end.not_to change(Follow, :count)
    expect(response).to redirect_to(root_path)
  end

  it "removes an item and its private linked alert records while keeping public filings and discarding obsolete delivery jobs" do
    filing = create(:filing)
    follow = create(:follow, user:)
    delivery = create(:alert_delivery, alert_rule: follow.alert_rule, filing:)
    api_login(user)
    delete api_v1_watchlist_item_path(follow.id), headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(Follow.exists?(follow.id)).to be(false)
    expect(AlertDelivery.exists?(delivery.id)).to be(false)
    expect(Filing.exists?(filing.id)).to be(true)
    expect { SendAlertJob.perform_now(delivery.id) }.not_to raise_error
  end

  it "supports deleting by an explicit JSON id on the collection route" do
    follow = create(:follow, user:)
    api_login(user)
    delete api_v1_watchlist_path, params: { id: follow.id }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(Follow.exists?(follow.id)).to be(false)
  end

  it "requires CSRF on add/remove and rejects invalid or unsupported target data" do
    create(:filing, issuer_ticker: "ACME")
    api_login(user)
    post api_v1_watchlist_path, params: { entity_type: "issuer", entity_key: "ACME" }, as: :json
    expect(response).to have_http_status(:forbidden)
    [ { entity_type: "unknown", entity_key: "ACME" }, { entity_type: "issuer", entity_key: "ACME%" },
      { entity_type: "person", entity_key: "456" }, { entity_type: "person", entity_key: [ "0000000456" ] },
      { entity_type: "issuer", entity_key: "ACME", user_id: user.id } ].each do |values|
      post api_v1_watchlist_path, params: values, headers: api_headers, as: :json
      expect(response).to have_http_status(:bad_request), values.inspect
    end
    get api_v1_watchlist_path, params: { entity_type: "unknown" }
    expect(response).to have_http_status(:bad_request)
    expect(user.follows.count).to eq(0)
  end
end
