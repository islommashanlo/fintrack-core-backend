# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 company prices" do
  include InstitutionalReadHelpers

  around { |example| travel_to(Time.utc(2026, 11, 10, 12)) { example.run } }

  let(:security) { map_security(cusip: "037833100", ticker: "ACME").security }
  let(:series) { price_series(security:) }
  let!(:filing) { create(:filing, issuer_ticker: "ACME", filed_at: Time.utc(2026, 11, 7, 20), ingested_at: Time.utc(2026, 11, 8)) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("MARKET_DATA_PUBLIC_PROVIDERS", "").and_return("fixture")
  end

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  def store_bars(target = series, bars: market_bars, observed_at: Time.current)
    MarketData::Ingest.call(series: target, bars:, observed_at:)
  end

  it "returns exact local bars, explicit source context, unknown calendar coverage and factual filing markers" do
    store_bars
    expect(MarketData::GapFill).not_to receive(:call)
    expect { get prices_api_v1_company_path("acme") }.not_to change(PriceDaily, :count)

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(data.fetch("series")).to include("id" => series.id, "figi" => security.figi,
      "provider" => "fixture", "provider_symbol" => "EXAMPLE.X", "currency" => "USD", "adjustment" => "unadjusted")
    expect(data.fetch("bars").first).to include("session_date" => "2026-11-05",
      "open" => "12.1234567890123456789", "volume" => "12345678901234567890.0")
    expect(data.fetch("filing_markers").sole).to include("accession" => filing.accession_no,
      "sec_url" => filing.sec_url, "filed_at" => filing.filed_at.iso8601(3), "ingested_at" => filing.ingested_at.iso8601(3),
      "marker_date" => "2026-11-07", "data_age_days" => 3)
    expect(meta).to include("status" => "available", "range" => "3m", "from" => "2026-08-11", "to" => "2026-11-10",
      "total_count" => 3, "disclaimer" => FilingsIntel::DISCLAIMER)
    expect(meta.fetch("coverage")).to include("stored_bar_count" => 3, "complete" => nil,
      "missing_sessions" => nil, "calendar_available" => false, "prices_fetched" => false)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:get, /https?:/)
  end

  it "never publishes stored prices or source context without an approved provider key" do
    store_bars
    allow(ENV).to receive(:fetch).with("MARKET_DATA_PUBLIC_PROVIDERS", "").and_return("")
    get prices_api_v1_company_path("ACME"), params: { series_id: series.id }
    expect(response).to have_http_status(:ok)
    expect(data).to include("series" => nil, "bars" => [])
    expect(meta).to include("status" => "redistribution_disabled", "total_count" => 0)
    expect(data.fetch("filing_markers").pluck("accession")).to eq([ filing.accession_no ])
  end

  it "keeps unapproved series private even when another provider is approved" do
    store_bars(price_series(security:, provider: "private_vendor"))
    get prices_api_v1_company_path("ACME")
    expect(meta.fetch("status")).to eq("series_unavailable")
    expect(data.fetch("bars")).to be_empty
    get prices_api_v1_company_path("ACME"), params: { series_id: PriceSeries.sole.id }
    expect(response).to have_http_status(:not_found)
  end

  it "reports missing mappings and missing stored bars without implying complete coverage" do
    get prices_api_v1_company_path("ACME")
    expect(meta.fetch("status")).to eq("security_unmapped")
    series
    get prices_api_v1_company_path("ACME")
    expect(meta.fetch("status")).to eq("available")
    expect(meta.fetch("coverage")).to include("stored_bar_count" => 0, "complete" => nil)
  end

  it "refuses automatic selection among multiple security mappings or incompatible price series" do
    store_bars
    other = price_series(security:, currency: "EUR")
    get prices_api_v1_company_path("ACME")
    expect(meta.fetch("status")).to eq("series_ambiguous")
    expect(data.fetch("series")).to be_nil
    second_security = map_security(cusip: "594918104", ticker: "ACME", figi: "TESTOTHER").security
    store_bars(price_series(security: second_security))
    get prices_api_v1_company_path("ACME")
    expect(meta.fetch("status")).to eq("security_ambiguous")
    get prices_api_v1_company_path("ACME"), params: { series_id: other.id }
    expect(data.fetch("series")).to include("id" => other.id, "currency" => "EUR")
    expect(data.fetch("bars")).to be_empty
  end

  it "rejects a series belonging to another ticker and ignores stale or future mappings" do
    other = price_series
    get prices_api_v1_company_path("ACME"), params: { series_id: other.id }
    expect(response).to have_http_status(:not_found)
    store_bars
    security.cusip_security_mappings.update_all(status: "stale")
    get prices_api_v1_company_path("ACME")
    expect(meta.fetch("status")).to eq("security_unmapped")
    security.cusip_security_mappings.update_all(status: "mapped", first_seen_at: 1.day.from_now)
    get prices_api_v1_company_path("ACME")
    expect(meta.fetch("status")).to eq("security_unmapped")
  end

  it "pins the date window, observation cutoff, row ceiling and marker set across cursor pages" do
    store_bars
    delayed = create(:filing, issuer_ticker: "ACME", filed_at: filing.filed_at,
                     ingested_at: filing.ingested_at, parse_status: "pending")
    get prices_api_v1_company_path("ACME"), params: { limit: 1 }
    cursor, snapshot = meta.fetch("next_cursor"), meta.fetch("as_of")
    extra = MarketData::DailyBar.new(**market_bars.first.to_h.merge(session_date: Date.new(2026, 11, 8)))
    store_bars(bars: [ extra ])
    create(:filing, issuer_ticker: "ACME", filed_at: filing.filed_at, ingested_at: Time.current)
    travel 13.hours
    delayed.update!(parse_status: "parsed", parsed_at: Time.current)
    get prices_api_v1_company_path("ACME"), params: { limit: 100, cursor: }
    expect(meta).to include("as_of" => snapshot, "total_count" => 3, "to" => "2026-11-10")
    expect(data.fetch("bars").pluck("session_date")).to eq(%w[2026-11-06 2026-11-09])
    expect(data.fetch("filing_markers").pluck("accession")).to eq([ filing.accession_no ])
  end

  it "keeps original and amendment markers on their actual UTC filing dates without shifting to sessions" do
    amended = create(:filing, issuer_ticker: "ACME", form_type: "4/A", amends_accession_no: filing.accession_no,
      filed_at: Time.new(2026, 11, 7, 23, 0, 0, "-05:00"), ingested_at: Time.utc(2026, 11, 9))
    store_bars
    get prices_api_v1_company_path("ACME")
    markers = data.fetch("filing_markers")
    expect(markers.pluck("accession")).to eq([ amended.accession_no, filing.accession_no ])
    expect(markers.first).to include("marker_date" => "2026-11-08", "is_amendment" => true, "form_type" => "4/A")
    expect(data.fetch("bars").pluck("session_date")).not_to include("2026-11-08")
  end

  it "rejects a continuation if automatic series resolution has become ambiguous" do
    store_bars
    get prices_api_v1_company_path("ACME"), params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    price_series(security:, adjustment: "split_adjusted")
    get prices_api_v1_company_path("ACME"), params: { cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "excludes future observations and out-of-range bars and supports reverse date sorting" do
    store_bars(bars: market_bars.first(2), observed_at: 1.day.from_now)
    store_bars(bars: [ market_bars.last ])
    old = MarketData::DailyBar.new(**market_bars.first.to_h.merge(session_date: Date.new(2025, 11, 10)))
    store_bars(bars: [ old ])
    get prices_api_v1_company_path("ACME"), params: { range: "1y", sort: "-date" }
    expect(data.fetch("bars").pluck("session_date")).to eq([ "2026-11-09" ])
    expect(meta.fetch("from")).to eq("2025-11-11")
  end

  it "bounds marker previews and excludes other issuers, share classes, failed and unavailable filings" do
    21.times { create(:filing, issuer_ticker: "ACME", filed_at: filing.filed_at, ingested_at: filing.ingested_at) }
    create(:filing, issuer_ticker: "ACME", issuer_cik: "0000000999", filed_at: 5.days.ago)
    create(:filing, issuer_ticker: "ACME.A")
    create(:filing, issuer_ticker: "ACME", parse_status: "failed")
    create(:filing, issuer_ticker: "ACME", ingested_at: 1.day.from_now)
    create(:filing, issuer_ticker: "ACME", filed_at: 1.day.from_now)
    get prices_api_v1_company_path("ACME")
    expect(data.fetch("filing_markers").size).to eq(20)
    expect(meta.fetch("filing_markers")).to include("total_count" => 22, "shown" => 20, "truncated" => true)
  end

  it "rejects invalid or nested filters, excessive limits and forged or mismatched cursors" do
    store_bars
    [ { range: "max" }, { series_id: "-1" }, { series_id: "1 OR 1=1" }, { range: [ "1m" ] },
      { limit: 101 }, { sort: "close" }, { from: "2020-01-01" }, { cursor: "forged" } ].each do |parameters|
      get prices_api_v1_company_path("ACME"), params: parameters
      expect(response).to have_http_status(:bad_request)
    end
    get prices_api_v1_company_path("ACME"), params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    get prices_api_v1_company_path("ACME"), params: { cursor:, range: "1m" }
    expect(response).to have_http_status(:bad_request)
    allow(ENV).to receive(:fetch).with("MARKET_DATA_PUBLIC_PROVIDERS", "").and_return("")
    get prices_api_v1_company_path("ACME"), params: { cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "returns 404 for unknown companies and omits markers for a mapped security without an issuer identity" do
    get prices_api_v1_company_path("UNKNOWN")
    expect(response).to have_http_status(:not_found)
    store_bars(price_series)
    map_security(cusip: "594918104", ticker: "EXAMPLE", figi: "TESTMAPPED")
    get prices_api_v1_company_path("EXAMPLE")
    expect(response).to have_http_status(:ok)
    expect(data.fetch("filing_markers")).to be_empty
  end
end
