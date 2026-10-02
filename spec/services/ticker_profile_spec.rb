# frozen_string_literal: true

require "rails_helper"

RSpec.describe TickerProfile do
  let(:as_of) { Time.utc(2026, 10, 2, 12, 0) }

  it "returns issuer activity from the ticker's parsed Form 4 filings" do
    filing = create(:filing, filed_at: as_of - 1.day, issuer_cik: "0000000123",
                             issuer_name: "Acme Corp", issuer_ticker: "ACME")
    create(:insider_transaction, filing:, insider_cik: "0000000456", insider_name: "Jane Doe",
                                 transaction_code: "P", shares: 500, price: 25)

    profile = described_class.new(ticker: "acme", as_of:)

    expect(profile.issuer).to include("issuer_name" => "Acme Corp", "issuer_ticker" => "ACME")
    expect(profile.summary).to include("purchase_count" => 1, "insider_count" => 1,
                                       "purchase_value" => BigDecimal("12500"))
    expect(profile.transactions.first).to include("insider_name" => "Jane Doe", "transaction_code" => "P")
  end

  it "shows mapped institutional holdings without guessing unmapped CUSIPs" do
    institution = create(:institutional_filer, name: "Acme Capital")
    report = create(:institutional_report, institutional_filer: institution)
    create(:institutional_holding, institutional_report: report, cusip: "037833100",
                                   name_of_issuer: "ACME CORP", value_usd: 50_000)
    security = Security.create!(figi: "BBG000000001", ticker: "ACME", name: "Acme Corp", source: "openfigi")
    CusipSecurityMapping.create!(cusip: "037833100", security:, source: "openfigi", result_seq: 0,
                                 status: "mapped", first_seen_at: Time.current, last_checked_at: Time.current)

    holdings = described_class.new(ticker: "ACME", as_of: as_of).institutional_holdings

    expect(holdings).to include(
      include("institution_name" => "Acme Capital", "cusip" => "037833100", "value_usd" => BigDecimal("50000"))
    )
  end
end
