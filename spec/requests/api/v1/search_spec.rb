# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 grouped search" do
  include InstitutionalReadHelpers
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }

  def data = response.parsed_body.fetch("data")
  def meta = response.parsed_body.fetch("meta")
  def search(query, **options) = get(api_v1_search_path, params: { q: query, **options })

  def company(name:, ticker:, **attributes)
    create(:filing, filed_at: 1.day.ago, issuer_name: name, issuer_ticker: ticker, **attributes)
  end

  def insider(name:, cik: "0000000901", issuer_cik: "0000000123", **attributes)
    filing = create(:filing, filed_at: 1.day.ago, issuer_cik:)
    create(:insider_transaction, filing:, insider_name: name, insider_cik: cik, **attributes)
  end

  it "returns public grouped results with profile links and provenance without requiring a purchase" do
    issuer = company(name: "Acme Widgets", ticker: "ACMW")
    owner = insider(name: "Acme Director", transaction_code: "M", security_table: "derivative", owner_seq: 2)
    fund = create(:institutional_filer, name: "Acme Capital")
    report = create_13f(fund:, filed_at: 1.day.ago)
    search("Acme")
    expect(response).to have_http_status(:ok)
    expect(data.keys).to eq(%w[companies funds insiders])
    expect(data.fetch("companies").sole).to include("entity_type" => "issuer", "entity_key" => "ACMW",
      "name" => "Acme Widgets", "ticker" => "ACMW", "profile_path" => "/api/v1/companies/ACMW", "accession" => issuer.accession_no)
    expect(data.fetch("funds").sole).to include("entity_type" => "fund", "entity_key" => fund.cik,
      "profile_path" => "/api/v1/funds/#{fund.cik}", "accession" => report.filing.accession_no)
    expect(data.fetch("insiders").sole).to include("entity_type" => "person", "entity_key" => owner.insider_cik,
      "profile_path" => "/api/v1/insiders/#{owner.insider_cik}", "accession" => owner.accession_no)
    data.values.flatten.each do |row|
      expect(row).to include("sec_url", "filed_at", "accepted_at", "ingested_at", "data_age_days")
    end
    expect(meta).to include("q" => "Acme", "disclaimer" => FilingsIntel::DISCLAIMER)
    expect(meta.fetch("groups").values).to all(include("total_count" => 1, "sort" => "relevance", "limit" => 5))
  end

  it "ranks exact tickers and names ahead of prefixes, substrings and fuzzy names" do
    company(name: "Exact Corporation", ticker: "ACME")
    company(name: "Acme", ticker: "NAME")
    company(name: "Acme Prefix", ticker: "PFX")
    company(name: "Another Acme Business", ticker: "SUB")
    company(name: "Acm", ticker: "FUZ")
    search("acme", type: "companies", limit: "20")
    expect(data.fetch("companies").pluck("ticker")).to eq(%w[ACME NAME PFX SUB FUZ])
    expect(data.fetch("companies").pluck("match_type")).to eq(%w[exact_ticker exact_name prefix substring fuzzy])
  end

  it "finds misspelled names using the fixed trigram threshold and restores connection settings" do
    create(:institutional_filer, name: "Renaissance Technologies")
    connection = ApplicationRecord.connection
    connection.execute("SET LOCAL pg_trgm.similarity_threshold = 0.95")
    search("Renaissnce Technologies", type: "funds")
    expect(data.fetch("funds").sole).to include("name" => "Renaissance Technologies", "match_type" => "fuzzy")
    expect(connection.select_value("SHOW pg_trgm.similarity_threshold")).to eq("0.95")
  end

  it "matches zero-padded CIKs exactly and keeps share-class ticker punctuation distinct" do
    company(name: "Class B", ticker: "BRK.B", issuer_cik: "0000000123")
    company(name: "Class A", ticker: "BRK.A", issuer_cik: "0000000123")
    owner = insider(name: "Different Owner", cik: "0000000123", issuer_cik: "0000000999")
    fund = create(:institutional_filer, cik: "0000000123", name: "Different Manager")
    search("123")
    expect(data.fetch("companies").pluck("ticker")).to contain_exactly("BRK.A", "BRK.B")
    expect(data.fetch("insiders").sole.fetch("cik")).to eq(owner.insider_cik)
    expect(data.fetch("funds").sole).to include("cik" => fund.cik, "match_type" => "exact_cik")
    search("brk.b", type: "companies")
    expect(data.fetch("companies").sole).to include("ticker" => "BRK.B", "match_type" => "exact_ticker")
  end

  it "deduplicates profiles before matching and does not promote a historical name as the latest name" do
    company(name: "Obsolete Zephyr", ticker: "NAME", filed_at: 10.days.ago)
    latest = company(name: "Modern Quartz", ticker: "NAME", filed_at: 1.day.ago, form_type: "4/A")
    insider(name: "Obsolete Zephyr", cik: "0000000901")
    fresh_owner = insider(name: "Modern Quartz", cik: "0000000901")
    fresh_owner.filing.update!(filed_at: 1.hour.ago)
    search("Obsolete Zephyr")
    expect(data.fetch("companies")).to eq([])
    expect(data.fetch("insiders")).to eq([])
    search("Modern Quartz")
    expect(data.fetch("companies").sole.fetch("accession")).to eq(latest.accession_no)
    expect(data.fetch("insiders").sole.fetch("accession")).to eq(fresh_owner.accession_no)
  end

  it "excludes future, failed and unsupported filings from company and insider identity" do
    company(name: "Invisible Candidate", ticker: "FUT", filed_at: 1.day.from_now)
    company(name: "Invisible Candidate", ticker: "BAD", parse_status: "failed")
    company(name: "Invisible Candidate", ticker: "OTHER", form_type: "144")
    future = insider(name: "Invisible Candidate")
    future.filing.update!(filed_at: 1.day.from_now)
    failed = insider(name: "Invisible Candidate", cik: "0000000902")
    failed.filing.update!(parse_status: "failed")
    search("Invisible Candidate")
    expect(data.values).to all(eq([]))
  end

  it "includes header-only owners and blank transaction names only when a visible filing supports the CIK" do
    create(:filer, cik: "0000000901", name: "Header Director")
    header = create(:filing, filed_at: 1.day.ago, owner_ciks: [ "0000000901" ])
    create(:filer, cik: "0000000902", name: "Fallback Director")
    insider(name: "", cik: "0000000902")
    create(:filer, cik: "0000000903", name: "Orphan Director")
    search("Director", type: "insiders")
    expect(data.fetch("insiders").pluck("cik")).to contain_exactly("0000000901", "0000000902")
    expect(data.fetch("insiders").find { |row| row["cik"] == "0000000901" }.fetch("accession")).to eq(header.accession_no)
  end

  it "uses existing mapped securities as a fallback and leaves absent filing evidence null" do
    mapped = map_security(cusip: "037833100", ticker: "MAP")
    mapped.security.update!(name: "Mapped Example")
    map_security(cusip: "594918104", ticker: "AMB", figi: "BBG000000002").update!(status: "ambiguous")
    map_security(cusip: "999999999", ticker: "FUT", figi: "BBG000000003").update!(first_seen_at: 1.day.from_now)
    search("MAP", type: "companies")
    row = data.fetch("companies").sole
    expect(row).to include("name" => "Mapped Example", "cik" => nil, "accession" => nil, "sec_url" => nil, "filed_at" => nil)
    search("AMB", type: "companies")
    expect(data.fetch("companies")).to eq([])
    search("FUT", type: "companies")
    expect(data.fetch("companies")).to eq([])
    source = company(name: "Authoritative Form Four", ticker: "MAP")
    search("MAP", type: "companies")
    expect(data.fetch("companies").sole).to include("name" => "Authoritative Form Four", "accession" => source.accession_no)
  end

  it "keeps directory funds discoverable without inventing provenance for invalid or missing reports" do
    fund = create(:institutional_filer, name: "Atlas Directory")
    create_13f(fund:, filed_at: 1.day.from_now)
    create_13f(fund:, filed_at: 1.day.ago, status: "failed")
    search("Atlas", type: "funds")
    expect(data.fetch("funds").sole).to include("cik" => fund.cik, "accession" => nil, "ingested_at" => nil, "data_age_days" => nil)
  end

  it "supports signed group cursors, deterministic ranking ties and ingestion ceilings" do
    funds = 7.times.map { |i| create(:institutional_filer, name: format("Atlas Fund %02d", i)) }
    search("Atlas", limit: "2")
    rows = data.fetch("funds")
    cursor = meta.dig("groups", "funds", "next_cursor")
    expect(meta.dig("groups", "funds", "total_count")).to eq(7)
    create(:institutional_filer, name: "Atlas Fund 00 Late")
    while cursor
      search("Atlas", type: "funds", sort: "relevance", limit: "2", cursor:)
      expect(response).to have_http_status(:ok)
      rows += data.fetch("funds")
      cursor = meta.dig("groups", "funds", "next_cursor")
    end
    expect(rows.pluck("cik")).to eq(funds.map(&:cik))
    expect(rows.pluck("cik").uniq.length).to eq(7)
    search("Atlas", type: "funds", limit: "1")
    cursor = meta.dig("groups", "funds", "next_cursor")
    [ { q: "Other", type: "funds" }, { q: "Atlas", type: "companies" }, { q: "Atlas", type: "all" } ].each do |options|
      get api_v1_search_path, params: options.merge(cursor:)
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "binds literal wildcard, quote and placeholder characters without executing query text" do
    names = [ "100% Literal", "under_score", "Back\\slash", "literal :query's ? text", "x' OR TRUE --" ]
    names.each { |name| create(:institutional_filer, name:) }
    names.each do |name|
      search(name, type: "funds", limit: "20")
      expect(response).to have_http_status(:ok)
      expect(data.fetch("funds").first).to include("name" => name, "match_type" => "exact_name")
    end
    search("%", type: "funds")
    expect(data.fetch("funds").pluck("name")).to eq([ "100% Literal" ])
    search("_", type: "funds")
    expect(data.fetch("funds").pluck("name")).to eq([ "under_score" ])
  end

  it "normalizes whitespace and returns empty groups without leaking account or watchlist details" do
    create(:user, email_address: "privateperson@example.com", password: "password123")
    create(:institutional_filer, name: "Atlas Capital")
    search("  Atlas   Capital  ")
    expect(meta.fetch("q")).to eq("Atlas Capital")
    expect(data.fetch("funds").sole.fetch("name")).to eq("Atlas Capital")
    search("privateperson@example.com")
    expect(data.values).to all(eq([]))
    expect(meta.fetch("groups").values).to all(include("total_count" => 0, "has_more" => false, "next_cursor" => nil))
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects missing/blank/long/structured queries, invalid groups and unsafe pagination" do
    get api_v1_search_path
    expect(response).to have_http_status(:bad_request)
    [ { q: " " }, { q: "a" * 101 }, { q: "line\nbreak" }, { q: [ "Atlas" ] }, { type: "users" },
      { limit: "0" }, { limit: "21" }, { limit: "01" }, { sort: "name;DROP" }, { cursor: "bad" },
      { cursor: "tampered", type: "funds" } ].each do |options|
      get api_v1_search_path, params: { q: "Atlas", **options }
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "loads provenance in batches rather than querying once per result" do
    company(name: "Atlas Company", ticker: "ONE")
    measure = lambda do
      queries = []
      callback = lambda { |*args| queries << args.last[:sql] unless args.last[:name] == "SCHEMA" || args.last[:cached] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { search("Atlas", type: "companies", limit: "20") }
      expect(response).to have_http_status(:ok)
      queries.grep(/\ASELECT|\AWITH/).length
    end
    baseline = measure.call
    8.times { |i| company(name: "Atlas Company #{i}", ticker: "AT#{i}") }
    expect(measure.call).to be <= baseline + 1
    expect(data.fetch("companies").length).to eq(9)
  end
end
