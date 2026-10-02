# frozen_string_literal: true

require "rails_helper"

RSpec.describe Watchlist do
  it "returns followed insiders, institutions, and tickers with filing activity" do
    user = create(:user)
    insider_filing = create(:filing, filed_at: Time.utc(2026, 10, 1), issuer_ticker: "ACME")
    create(:insider_transaction, filing: insider_filing, insider_cik: "0000000456", insider_name: "Jane Doe")

    institution = create(:institutional_filer, cik: "0000000789", name: "Acme Capital")
    create(:institutional_report, institutional_filer: institution, filed_at: Time.utc(2026, 9, 1))

    ticker_filing = create(:filing, filed_at: Time.utc(2026, 10, 2), issuer_ticker: "ACME")
    create(:insider_transaction, filing: ticker_filing, insider_cik: "0000000999")

    create(:follow, user:, target_type: "Insider", target_key: "0000000456")
    create(:follow, user:, target_type: "InstitutionalFiler", target_key: institution.cik)
    create(:follow, user:, target_type: "Ticker", target_key: "ACME")

    entries = described_class.new(user:).entries

    expect(entries).to include(
      include("target_type" => "Insider", "label" => "Jane Doe", "activity_count" => 1),
      include("target_type" => "InstitutionalFiler", "label" => "Acme Capital", "activity_count" => 1),
      include("target_type" => "Ticker", "label" => "Example Corp", "activity_count" => 2)
    )
  end

  it "returns follows without activity" do
    user = create(:user)
    create(:follow, user:, target_type: "Ticker", target_key: "MISSING")

    entry = described_class.new(user:).entries.first

    expect(entry).to include("label" => "MISSING", "last_filed_at" => nil, "activity_count" => 0)
  end
end
