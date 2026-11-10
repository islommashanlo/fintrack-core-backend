# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 filings" do
  it "returns a Form 4 with factual transaction classifications and freshness" do
    filing = create(:filing, cik: "0000000123", filed_at: Time.utc(2026, 10, 1, 20, 0),
                    accepted_at: Time.utc(2026, 10, 1, 20, 0), ingested_at: Time.utc(2026, 10, 2, 12, 0))
    create(:insider_transaction, filing:, txn_seq: 1, transaction_code: "P", insider_name: "Jane Doe", shares: 500, price: 25)
    create(:insider_transaction, filing:, transaction_code: "A", txn_seq: 2, insider_name: "Jane Doe", shares: 100,
                                 price: nil)

    travel_to Time.utc(2026, 10, 5, 12, 0) do
      get api_v1_filing_path(filing.accession_no)
    end

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch("data")
    expect(body).to include(
      "accession" => filing.accession_no,
      "form_type" => "4",
      "sec_url" => filing.sec_url,
      "data_age_days" => 4
    )
    expect(body.fetch("transactions")).to include(
      include("activity_type" => "open_market", "direction" => "purchase", "transaction_code" => "P"),
      include("activity_type" => "administrative", "direction" => "other", "transaction_code" => "A")
    )
  end

  it "returns 13F reported and normalized holding values separately" do
    report = create(:institutional_report)
    holding = create(:institutional_holding, institutional_report: report, value_reported: BigDecimal("125"),
                     value_unit: "thousands", value_usd: BigDecimal("125000"), shares: 50)

    get api_v1_filing_path(report.filing.accession_no)

    expect(response).to have_http_status(:ok)
    row = response.parsed_body.fetch("data").fetch("holdings").first
    expect(row).to include("value_reported" => "125.0", "value_unit" => "thousands", "value_usd" => "125000.0",
                           "suspect" => holding.suspect, "sec_url" => report.filing.sec_url)
  end

  it "returns a JSON 404 for an unknown accession" do
    get api_v1_filing_path("0000000001-26-000001")

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => { "code" => "NOT_FOUND", "message" => "Resource not found" })
  end
end
