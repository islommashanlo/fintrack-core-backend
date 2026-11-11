# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 public entity news" do
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  before { approve_fixture_news }

  let(:identity) { company_news_identity }
  let(:issuer) { identity.first }

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  it "returns original headline/link metadata and scoped canonical mentions without fetching or exposing article text" do
    item = store_news(entities: [ issuer, news_entity(role: "fund") ])
    expect(News::Provider::Disabled).not_to receive(:new)
    expect { get news_api_v1_company_path("acme") }.not_to change(NewsItem, :count)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(data.sole).to include("id" => item.id, "title" => item.title, "source" => item.source,
      "url" => item.url, "provider" => "fixture", "published_at" => item.published_at.iso8601(3),
      "observed_at" => item.observed_at.iso8601(3))
    expect(data.sole.fetch("mentions").sole).to include("entity_type" => "issuer", "cik" => identity.last.issuer_cik)
    expect(data.sole.keys).not_to include("body", "content", "sec_url", "accession")
    expect(meta).to include("status" => "local_cache", "scope" => "issuer", "entity_resolved" => true,
      "complete" => nil, "fetched" => false, "disclaimer" => FilingsIntel::DISCLAIMER)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:get, /https?:/)
  end

  it "keeps publication disabled by default and never exposes an unapproved provider" do
    store_news(entities: [ issuer ])
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("")
    get news_api_v1_company_path("ACME")
    expect(data).to be_empty
    expect(meta).to include("status" => "publication_disabled", "total_count" => 0)
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("another")
    get news_api_v1_company_path("ACME"), params: { provider: "fixture" }
    expect(data).to be_empty
  end

  it "resolves fund and insider profiles to distinct canonical news roles" do
    person = news_entity(role: "person")
    cik = Filer.find(person.id).cik
    create(:filing, owner_ciks: [ cik ])
    fund = news_entity(role: "fund")
    item = store_news(entities: [ person, fund ])
    get news_api_v1_fund_path(InstitutionalFiler.find(fund.id).cik)
    expect(response).to have_http_status(:ok)
    expect(data.pluck("id")).to eq([ item.id ])
    expect(data.sole.fetch("mentions").pluck("entity_type")).to eq([ "fund" ])
    get news_api_v1_insider_path(cik)
    expect(response).to have_http_status(:ok)
    expect(data.sole.fetch("mentions")).to include(hash_including("entity_type" => "person", "cik" => cik))
  end

  it "does not guess news identities from ticker strings, issuer names or missing canonical records" do
    issuer
    unrelated = news_entity
    store_news(entities: [ unrelated ])
    get news_api_v1_company_path("ACME")
    expect(data).to be_empty
    create(:filing, issuer_ticker: "CACHE", issuer_cik: "0000000007")
    get news_api_v1_company_path("CACHE")
    expect(data).to be_empty
    expect(meta).to include("status" => "identity_unresolved", "entity_resolved" => false)
    get news_api_v1_company_path("UNKNOWN")
    expect(response).to have_http_status(:not_found)
    get news_api_v1_fund_path("0000000000")
    expect(response).to have_http_status(:not_found)
    get news_api_v1_insider_path("0000000000")
    expect(response).to have_http_status(:not_found)
  end

  it "withholds suppressed, marked-up and legacy restricted headlines before counting and pagination" do
    store_news(entities: [ issuer ], title: "Buy example shares")
    legacy = store_news(entities: [ issuer ], title: "Sell example shares")
    NewsItem.where(id: legacy.id).update_all(suppression_reason: nil)
    store_news(entities: [ issuer ], title: "<b>Example</b>")
    invalid_link = store_news(entities: [ issuer ])
    NewsItem.where(id: invalid_link.id).update_all(url: "javascript:alert(1)")
    safe = store_news(entities: [ issuer ], title: "Example shareholder meeting")
    get news_api_v1_company_path("ACME")
    expect(data.pluck("id")).to eq([ safe.id ])
    expect(meta.fetch("total_count")).to eq(1)
    expect(NewsItem.find(legacy.id).title).to eq("Sell example shares")
  end

  it "honors changed language policy without rewriting stored metadata" do
    item = store_news(entities: [ issuer ], title: "Example shareholder meeting")
    stub_const("Policy::BannedLanguageScan::BANNED_TERMS", /\bmeeting\b/i)
    get news_api_v1_company_path("ACME")
    expect(data).to be_empty
    expect(meta.fetch("total_count")).to eq(0)
    expect(item.reload.suppression_reason).to be_nil
  end

  it "pins article and mention ceilings and observation times across equal-time cursor pages" do
    first = store_news(entities: [ issuer ])
    second = store_news(entities: [ issuer ])
    unrelated = news_entity
    late_link = store_news(entities: [ unrelated ])
    get news_api_v1_company_path("ACME"), params: { limit: 1 }
    expect(data.pluck("id")).to eq([ second.id ])
    cursor, timestamp = meta.fetch("next_cursor"), meta.fetch("as_of")
    store_news(entities: [ issuer ])
    NewsMention.create!(news_item: late_link, entity: Filer.find(issuer.id), role: "issuer", observed_at: Time.current)
    travel 1.hour
    get news_api_v1_company_path("ACME"), params: { limit: 100, cursor: }
    expect(data.pluck("id")).to eq([ first.id ])
    expect(meta).to include("total_count" => 2, "as_of" => timestamp, "has_more" => false)
  end

  it "excludes future observations, future mention links and out-of-window items" do
    store_news(entities: [ issuer ], observed_at: 1.day.from_now)
    linked = store_news(entities: [ news_entity ])
    NewsMention.create!(news_item: linked, entity: Filer.find(issuer.id), role: "issuer", observed_at: 1.day.from_now)
    in_range = store_news(entities: [ issuer ], published_at: Time.utc(2026, 11, 9, 23, 59))
    store_news(entities: [ issuer ], published_at: Time.utc(2026, 11, 10))
    get news_api_v1_company_path("ACME"), params: { from: "2026-11-09", to: "2026-11-09" }
    expect(data.pluck("id")).to eq([ in_range.id ])
  end

  it "filters by exact source, kind and provider and supports ascending publication order" do
    store_news(entities: [ issuer ])
    selected = store_news(entities: [ issuer ], index: 1)
    get news_api_v1_company_path("ACME"), params: { kind: "press_release", source: selected.source, provider: "fixture", sort: "published_at" }
    expect(data.pluck("id")).to eq([ selected.id ])
  end

  it "rejects malformed filters, excessive ranges and limits, and forged or cross-entity cursors" do
    2.times { store_news(entities: [ issuer ]) }
    [ { from: "20261101" }, { to: "2027-01-01" }, { from: "2024-01-01" }, { from: "2026-11-10", to: "2026-11-01" },
      { kind: "prediction" }, { source: "x" * 201 }, { provider: "../fixture" }, { limit: 101 }, { sort: "title" },
      { cursor: "forged" }, { kind: [ "news" ] }, { q: "ignored" } ].each do |filters|
      get news_api_v1_company_path("ACME"), params: filters
      expect(response).to have_http_status(:bad_request)
    end
    get news_api_v1_company_path("ACME"), params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    fund = create(:institutional_filer)
    get news_api_v1_fund_path(fund.cik), params: { cursor: }
    expect(response).to have_http_status(:bad_request)
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("")
    get news_api_v1_company_path("ACME"), params: { cursor: }
    expect(response).to have_http_status(:bad_request)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end
end
