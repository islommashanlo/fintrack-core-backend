# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Filing pages" do
  it "shows parsed Form 4 transactions and the SEC source" do
    filing = create(:filing, cik: "0000000123", raw_path: "123/26/source.txt")
    create(:insider_transaction, filing:, insider_name: "Jane Doe", transaction_code: "P", shares: 500, price: 25)

    get filing_path(filing.accession_no)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Parsed SEC filing", filing.accession_no, "Jane Doe", "Purchase",
                                     "View original at SEC.gov", filing.edgar_url)
  end

  it "shows parsed 13F cover totals and holdings" do
    institution = create(:institutional_filer, cik: "0000000789", name: "Acme Capital")
    report = create(:institutional_report, institutional_filer: institution, table_entry_total: 1,
                    table_value_total: BigDecimal("100"))
    create(:institutional_holding, institutional_report: report, name_of_issuer: "ACME CORP",
                                   value_reported: BigDecimal("100"), value_usd: BigDecimal("100"), shares: 10)

    get filing_path(report.filing.accession_no)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("13F cover page", "Reported holdings", "ACME CORP", "$100.00", "Acme Capital")
  end

  it "returns not found for an unknown accession" do
    get filing_path("0000000001-26-000001")

    expect(response).to have_http_status(:not_found)
  end
end
