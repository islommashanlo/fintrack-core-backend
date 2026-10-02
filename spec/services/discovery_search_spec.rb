# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscoverySearch do
  let(:filed_at) { Time.utc(2026, 10, 1, 15, 0) }

  it "returns recent institutions, insiders, and issuers from parsed filings" do
    institution = create(:institutional_filer, name: "Acme Capital")
    create(:institutional_report, institutional_filer: institution, filed_at: filed_at)

    filing = create(:filing, filed_at:, issuer_name: "Acme Corp", issuer_ticker: "ACME")
    create(:insider_transaction, filing:, insider_name: "Jane Doe", transaction_code: "P")
    create(:insider_transaction, filing:, insider_name: "Jane Doe", transaction_code: "S")

    search = described_class.new

    expect(search.institutions).to include(
      include("name" => "Acme Capital", "reports" => 1, "latest_period" => Date.new(2026, 3, 31))
    )
    expect(search.insiders).to include(
      include("insider_name" => "Jane Doe", "purchases" => 1, "issuers" => 1)
    )
    expect(search.issuers).to include(
      include("issuer_name" => "Acme Corp", "issuer_ticker" => "ACME", "purchases" => 1, "insiders" => 1)
    )
  end

  it "does not include unparsed filings in insider or issuer discovery" do
    filing = create(:filing, :pending, issuer_cik: "0000000123")
    create(:insider_transaction, filing:, insider_name: "Pending Insider", transaction_code: "P")

    search = described_class.new(query: "Pending")

    expect(search.insiders).to be_empty
    expect(search.issuers).to be_empty
  end
end
