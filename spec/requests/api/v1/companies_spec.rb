# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 companies" do
  include OpenapiResponses
  include InstitutionalReadHelpers

  around { |example| travel_to(Time.utc(2026, 11, 10, 12)) { example.run } }

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  def issuer_filing(**attributes)
    create(:filing, issuer_ticker: "ACME", issuer_name: "Example Company", filed_at: Time.utc(2026, 10, 1), **attributes)
  end

  it "finds a company from administrative filings and matches tickers exactly" do
    filing = issuer_filing
    create(:insider_transaction, filing:, transaction_code: "A")
    issuer_filing(issuer_ticker: "ACME.A", issuer_name: "Different Share Class", filed_at: 1.day.ago)

    get api_v1_company_path("acme")
    expect_documented_response(path: "/companies/{ticker}")

    expect(data).to include("ticker" => "ACME", "name" => "Example Company", "cik" => filing.issuer_cik)
    expect(data.fetch("latest_filing")).to include("accession" => filing.accession_no,
                                                  "sec_url" => filing.sec_url, "data_age_days" => 40)
    expect(data.fetch("insider_summary")).to include("purchase_count" => 0, "sale_count" => 0, "insider_count" => 0)
    get api_v1_company_path("ACME.A")
    expect_documented_response(path: "/companies/{ticker}")
    expect(data).to include("ticker" => "ACME.A", "name" => "Different Share Class")
    get api_v1_company_path("ACM")
    expect_documented_response(path: "/companies/{ticker}")
    expect(response).to have_http_status(:not_found)
  end

  it "aggregates open-market activity without duplicate owners, derivative rows, stale or suspect values" do
    filing = issuer_filing
    create(:insider_transaction, filing:, shares: 10, price: 20)
    create(:insider_transaction, filing:, owner_seq: 2, insider_cik: "0000000789", shares: 10, price: 20)
    create(:insider_transaction, filing:, transaction_code: "S", shares: 5, price: 10)
    create(:insider_transaction, filing:, price_suspect: true)
    create(:insider_transaction, filing:, security_table: "derivative", shares: 1000)
    create(:insider_transaction, filing: issuer_filing(filed_at: 91.days.ago))
    create(:insider_transaction, filing: issuer_filing(filed_at: 1.day.from_now))

    get api_v1_company_path("ACME")
    expect_documented_response(path: "/companies/{ticker}")
    expect(data.fetch("insider_summary")).to include("window_days" => 90, "purchase_count" => 2,
      "sale_count" => 1, "insider_count" => 1, "purchase_value" => "200.0", "sale_value" => "50.0")
  end

  it "provides company insider filters and cursor pagination through the existing transaction contract" do
    filing = issuer_filing
    first = create(:insider_transaction, filing:, is_director: true)
    second = create(:insider_transaction, filing:, is_director: true)
    create(:insider_transaction, filing:, is_officer: true)
    create(:insider_transaction, filing: issuer_filing(issuer_ticker: "ACME.A"), is_director: true)

    get insiders_api_v1_company_path("ACME"), params: { role: "director", limit: 1 }
    expect(data.pluck("id")).to eq([ second.id ])
    cursor = meta.fetch("next_cursor")
    get insiders_api_v1_company_path("ACME"), params: { role: "director", limit: 1, cursor: }
    expect(data.pluck("id")).to eq([ first.id ])
    expect(meta).to include("total_count" => 2, "has_more" => false)
  end

  it "lists original and amended filing summaries without loading transaction or holding arrays" do
    original = issuer_filing
    amendment = issuer_filing(form_type: "4/A", amends_accession_no: original.accession_no, filed_at: 1.day.ago)
    original.update!(superseded_by_accession_no: amendment.accession_no)
    issuer_filing(parse_status: "failed")
    issuer_filing(filed_at: 1.day.from_now)
    issuer_filing(issuer_ticker: "ACME.A")

    get filings_api_v1_company_path("ACME"), params: { limit: 1 }
    expect(data.pluck("accession")).to eq([ amendment.accession_no ])
    expect(data.first).not_to have_key("transactions")
    cursor = meta.fetch("next_cursor")
    get filings_api_v1_company_path("ACME"), params: { limit: 1, cursor: }
    expect(data.pluck("accession")).to eq([ original.accession_no ])
    expect(data.first.fetch("superseded_by")).to eq(amendment.accession_no)
    expect(meta.fetch("total_count")).to eq(2)
  end

  it "finds a mapped company with no Form 4 filings without inventing a CIK" do
    map_security(cusip: "037833100", ticker: "ACME")

    get api_v1_company_path("ACME")
    expect_documented_response(path: "/companies/{ticker}")
    expect(data).to include("ticker" => "ACME", "name" => "Example Company", "cik" => nil, "latest_filing" => nil)
    expect(data.fetch("insider_summary")).to include("purchase_count" => 0, "sale_count" => 0)
  end

  it "uses exact cached mappings and each fund's latest known quarter for institutional ownership" do
    issuer_filing
    map_security(cusip: "037833100", ticker: "ACME")
    map_security(cusip: "594918104", ticker: "ACME.A", figi: "BBG000000002")
    fund = create(:institutional_filer)
    prior = create_13f(fund:, period: Date.new(2026, 3, 31))
    create(:institutional_holding, institutional_report: prior, shares: 999)
    current = create_13f(fund:)
    wanted = create(:institutional_holding, institutional_report: current)
    create(:institutional_holding, institutional_report: current, cusip: "594918104")
    create(:institutional_holding, institutional_report: current, cusip: "02079K305")
    future = create_13f(fund:, filed_at: 1.day.from_now, amendment_type: "RESTATEMENT")
    create(:institutional_holding, institutional_report: future)
    later_period = create_13f(fund:, period: Date.new(2026, 9, 30), filed_at: 1.day.from_now)
    create(:institutional_holding, institutional_report: later_period)

    get institutional_api_v1_company_path("ACME")
    expect(data.pluck("id")).to eq([ wanted.id ])
    expect(data.first).to include("accession" => current.filing.accession_no, "sec_url" => current.filing.sec_url)

    get institutional_api_v1_company_path("ACME"), params: { period: "2026-03-31" }
    expect(data.pluck("id")).to eq(prior.institutional_holdings.pluck(:id))
  end

  it "keeps options and same-CUSIP rows distinct and paginates institutional rows across funds" do
    issuer_filing
    map_security(cusip: "037833100", ticker: "ACME")
    first = create_13f(fund: create(:institutional_filer))
    a = create(:institutional_holding, institutional_report: first, value_usd: 100)
    b = create(:institutional_holding, institutional_report: first, value_usd: 100, put_call: "PUT")
    second = create_13f(fund: create(:institutional_filer))
    c = create(:institutional_holding, institutional_report: second, value_usd: 100)

    get institutional_api_v1_company_path("ACME"), params: { limit: 1 }
    expect(data.pluck("id")).to eq([ c.id ])
    cursor = meta.fetch("next_cursor")
    get institutional_api_v1_company_path("ACME"), params: { limit: 2, cursor: }
    expect(data.pluck("id")).to eq([ b.id, a.id ])
    expect(meta).to include("total_count" => 3, "has_more" => false)
    get institutional_api_v1_company_path("ACME"), params: { put_call: "PUT" }
    expect(data.pluck("id")).to eq([ b.id ])
  end

  it "does not match an ambiguous mapping or an issuer name that resembles a ticker" do
    issuer_filing
    map_security(cusip: "037833100", ticker: "ACME").update!(status: "ambiguous")
    report = create_13f(fund: create(:institutional_filer))
    create(:institutional_holding, institutional_report: report, name_of_issuer: "ACME")

    get institutional_api_v1_company_path("ACME")
    expect(data).to eq([])
  end

  it "returns JSON errors for unknown companies and invalid parameters" do
    get api_v1_company_path("UNKNOWN")
    expect_documented_response(path: "/companies/{ticker}")
    expect(response).to have_http_status(:not_found)
    issuer_filing
    get filings_api_v1_company_path("ACME"), params: { form_type: "13F-HR" }
    expect(response).to have_http_status(:bad_request)
    get institutional_api_v1_company_path("ACME"), params: { period: "2026-09-29" }
    expect(response).to have_http_status(:bad_request)
    get api_v1_company_path("ACME"), params: { q: "ignored" }
    expect_documented_response(path: "/companies/{ticker}")
    expect(response).to have_http_status(:bad_request)
  end
end
