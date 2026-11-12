# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Company insider aggregate windows" do
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }

  def trade(at: Time.current, filing: nil, **attributes)
    filing ||= create(:filing, issuer_ticker: "ACME", filed_at: at)
    create(:insider_transaction, filing:, shares: 10, price: 20, **attributes)
  end

  def company
    get api_v1_company_path("ACME")
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("data")
  end

  it "returns all three acceptance-time windows with exclusive starts and inclusive ends" do
    trade(at: 365.days.ago)
    trade(at: 90.days.ago)
    trade(at: 30.days.ago)
    trade(at: 29.days.ago)
    trade
    trade(at: 1.second.from_now)
    rows = company.fetch("insider_summaries")
    expect(rows.pluck("window_days")).to eq([ 30, 90, 365 ])
    expect(rows.pluck("purchase_count")).to eq([ 2, 3, 4 ])
    expect(rows.pluck("purchase_value")).to eq([ "400.0", "600.0", "800.0" ])
  end

  it "preserves the legacy summary shape and known subtotals while leaving incomplete net value null" do
    trade(shares: BigDecimal("12.5"), price: BigDecimal("20.25"))
    trade(transaction_code: "S", shares: 5, price: 10)
    trade(price: nil)
    trade(price_suspect: true)
    trade(shares: nil)
    data = company
    legacy = data.fetch("insider_summary")
    expect(legacy.keys).to match_array(%w[window_days purchase_count sale_count insider_count purchase_value sale_value])
    expect(legacy).to include("purchase_count" => 4, "sale_count" => 1, "purchase_value" => "253.125", "sale_value" => "50.0")
    data.fetch("insider_summaries").each do |row|
      expect(row).to include("transactions_without_usable_price" => 3, "net_open_market_value" => nil)
    end
  end

  it "counts canonical rows by code, including administrative and unknown codes, without counting duplicate owners or derivatives" do
    first = trade
    trade(filing: first.filing, owner_seq: 2, insider_cik: "0000000789", txn_seq: first.txn_seq)
    trade(transaction_code: "S", insider_cik: "0000000789", shares: 5)
    trade(transaction_code: "A", insider_cik: "0000000999")
    trade(transaction_code: nil)
    trade(security_table: "derivative")
    row = company.fetch("insider_summaries").first
    expect(row).to include("insider_count" => 2, "counts_by_code" => { "P" => 1, "S" => 1, "A" => 1, "unknown" => 1 },
      "net_open_market_value" => "100.0", "transactions_without_usable_price" => 0)
  end

  it "keeps a known zero value distinct from missing values and empty history" do
    trade(price: 0)
    row = company.fetch("insider_summaries").first
    expect(row).to include("purchase_value" => "0.0", "net_open_market_value" => "0.0", "transactions_without_usable_price" => 0)
    trade(at: 1.day.ago, transaction_code: "S", shares: 1, price: 5)
    expect(company.fetch("insider_summaries").first.fetch("net_open_market_value")).to eq("-5.0")
  end

  it "resolves amendments at the request time without adding originals and replacements together" do
    original = trade(at: 40.days.ago, shares: 100)
    amendment = create(:filing, issuer_ticker: "ACME", form_type: "4/A", filed_at: 1.day.ago, amends_accession_no: original.accession_no)
    trade(filing: amendment, shares: 25)
    future = create(:filing, issuer_ticker: "ACME", form_type: "4/A", filed_at: 1.day.from_now, amends_accession_no: original.accession_no)
    trade(filing: future, shares: 999)
    rows = company.fetch("insider_summaries")
    expect(rows.pluck("purchase_count")).to eq([ 1, 1, 1 ])
    expect(rows.pluck("purchase_value")).to eq([ "500.0" ] * 3)
  end

  it "scopes both exact ticker and current issuer identity and excludes failed sources" do
    trade(at: 1.day.ago)
    other = create(:filing, issuer_ticker: "ACME", issuer_cik: "0000000999", filed_at: 2.days.ago)
    trade(filing: other)
    suffix = create(:filing, issuer_ticker: "ACME.A", filed_at: 2.days.ago)
    trade(filing: suffix)
    failed = create(:filing, issuer_ticker: "ACME", parse_status: "failed", filed_at: Time.current)
    trade(filing: failed)
    expect(company.fetch("insider_summaries").pluck("purchase_count")).to eq([ 1, 1, 1 ])
  end

  it "returns explicit empty windows for mapped companies without filing history" do
    map_security(cusip: "037833100", ticker: "ACME")
    data = company
    expect(data.fetch("latest_filing")).to be_nil
    data.fetch("insider_summaries").each do |row|
      expect(row).to include("purchase_count" => 0, "sale_count" => 0, "insider_count" => 0, "counts_by_code" => {},
        "transactions_without_usable_price" => 0, "purchase_value" => nil, "sale_value" => nil, "net_open_market_value" => nil)
    end
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
