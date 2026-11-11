# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 private watchlist news" do
  include ApiAccounts

  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  before { approve_fixture_news }
  let(:user) { create(:user, password: "password123") }

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  def follow(type, key, **attributes)
    create(:follow, user:, target_type: type, target_key: key, skip_default_alert_rule: true, **attributes)
  end

  it "requires authentication and refuses an unsupported global feed" do
    get api_v1_news_path, params: { watchlist: "true" }
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    api_login(user)
    get api_v1_news_path, params: { watchlist: "false" }
    expect(response).to have_http_status(:bad_request)
  end

  it "unions issuer/fund/person follows in SQL and emits a shared story once with matching mentions only" do
    issuer, filing = company_news_identity
    fund, person, other = news_entity(role: "fund"), news_entity(role: "person"), news_entity
    shared = store_news(entities: [ issuer, fund, person, other ])
    store_news(entities: [ other ])
    follow("Ticker", "ACME")
    follow("InstitutionalFiler", InstitutionalFiler.find(fund.id).cik)
    follow("Insider", Filer.find(person.id).cik)
    api_login(user)
    get api_v1_news_path, params: { watchlist: "true" }
    expect(response).to have_http_status(:ok)
    expect(data.pluck("id")).to eq([ shared.id ])
    expect(data.sole.fetch("mentions").pluck("entity_type")).to contain_exactly("issuer", "fund", "person")
    expect(data.sole.fetch("mentions").pluck("cik")).to include(filing.issuer_cik)
    expect(meta).to include("scope" => "watchlist", "total_count" => 1)
    expect(response.body).not_to include('"user_id"', '"follow_id"')
  end

  it "isolates accounts and excludes removed or future follow memberships" do
    active, removed, future, stranger = Array.new(4) { news_entity(role: "fund") }
    own = store_news(entities: [ active ])
    [ removed, future, stranger ].each { |entity| store_news(entities: [ entity ]) }
    follow("InstitutionalFiler", InstitutionalFiler.find(active.id).cik)
    follow("InstitutionalFiler", InstitutionalFiler.find(removed.id).cik, removed_at: Time.current)
    follow("InstitutionalFiler", InstitutionalFiler.find(future.id).cik, followed_at: 1.day.from_now)
    stranger_user = create(:user, email_address: "stranger@example.com")
    create(:follow, user: stranger_user, target_type: "InstitutionalFiler", target_key: InstitutionalFiler.find(stranger.id).cik, skip_default_alert_rule: true)
    api_login(user)
    get api_v1_news_path
    expect(data.pluck("id")).to eq([ own.id ])
  end

  it "binds cursors to the user and invalidates them immediately on membership changes" do
    fund = news_entity(role: "fund")
    2.times { store_news(entities: [ fund ]) }
    membership = follow("InstitutionalFiler", InstitutionalFiler.find(fund.id).cik)
    api_login(user)
    get api_v1_news_path, params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    api_login(create(:user, email_address: "other@example.com", password: "password123"))
    get api_v1_news_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
    api_login(user)
    membership.update!(removed_at: Time.current)
    get api_v1_news_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
    get api_v1_news_path
    expect(data).to be_empty
  end

  it "uses the latest known issuer CIK for a ticker rather than all historical issuers" do
    original, filing = company_news_identity
    replacement = news_entity
    create(:filing, issuer_ticker: "ACME", issuer_cik: Filer.find(replacement.id).cik,
                    filed_at: filing.filed_at + 1.day, ingested_at: filing.filed_at + 1.day)
    store_news(entities: [ original ])
    expected = store_news(entities: [ replacement ])
    follow("Ticker", "ACME")
    api_login(user)
    get api_v1_news_path
    expect(data.pluck("id")).to eq([ expected.id ])
  end

  it "caps matching mention previews in SQL while keeping counts accurate" do
    funds = Array.new(21) { news_entity(role: "fund") }
    story = store_news(entities: funds.first(20))
    NewsMention.create!(news_item: story, entity: InstitutionalFiler.find(funds.last.id), role: "fund", observed_at: Time.current)
    funds.each { |fund| follow("InstitutionalFiler", InstitutionalFiler.find(fund.id).cik) }
    api_login(user)
    get api_v1_news_path
    expect(data.sole.fetch("mentions").size).to eq(20)
    expect(data.sole.fetch("mentions_meta")).to include("total_count" => 21, "shown" => 20, "truncated" => true)
  end
end
