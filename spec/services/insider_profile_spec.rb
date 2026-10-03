# frozen_string_literal: true

require "rails_helper"

RSpec.describe InsiderProfile do
  let(:as_of) { Time.utc(2026, 10, 2, 12, 0) }
  let(:insider_cik) { "0000000456" }

  it "returns point-in-time purchases and sales for one insider" do
    purchase_filing = create(:filing, filed_at: as_of - 1.day, issuer_name: "Acme Corp", issuer_ticker: "ACME",
                             aff10b5_one: true)
    create(:insider_transaction, filing: purchase_filing, insider_cik:, insider_name: "Jane Doe",
                                 transaction_code: "P", shares: 500, price: 25)
    sale_filing = create(:filing, filed_at: as_of - 2.days, issuer_cik: "0000000457",
                                 issuer_name: "Beta Corp", issuer_ticker: "BETA")
    create(:insider_transaction, filing: sale_filing, insider_cik:, insider_name: "Jane Doe",
                                 transaction_code: "S", shares: 100, price: 10)

    profile = described_class.new(insider_cik:, as_of:)

    expect(profile.name).to eq("Jane Doe")
    expect(profile.summary).to include("purchase_count" => 1, "sale_count" => 1, "issuer_count" => 2,
                                       "purchase_value" => BigDecimal("12500"))
    expect(profile.transactions.map { |row| row["transaction_code"] }).to eq(%w[P S])
    expect(profile.transactions.first["filing_cik"]).to eq(purchase_filing.cik)
    expect(profile.transactions.first["plan_status"]).to eq("10b5-1 plan disclosed")
  end

  it "leaves suspect prices out of reported purchase value" do
    filing = create(:filing, filed_at: as_of - 1.day)
    create(:insider_transaction, filing:, insider_cik:, insider_name: "Jane Doe", transaction_code: "P",
                                 shares: 100, price: 61_216, price_suspect: true)

    expect(described_class.new(insider_cik:, as_of:).summary).to include(
      "purchase_count" => 1, "purchase_value" => nil, "purchases_without_usable_price" => 1
    )
  end

  it "aggregates issuer activity with point-in-time purchase values" do
    recent = create(:filing, filed_at: as_of - 1.day, issuer_cik: "0000000123",
                             issuer_name: "Acme Corp", issuer_ticker: "ACME")
    create(:insider_transaction, filing: recent, insider_cik:, insider_name: "Jane Doe",
                                 transaction_code: "P", shares: 500, price: 25)
    create(:insider_transaction, filing: recent, insider_cik:, insider_name: "Jane Doe",
                                 transaction_code: "S", shares: 100, price: 30)
    older = create(:filing, filed_at: as_of - 400.days, issuer_cik: "0000000457",
                            issuer_name: "Beta Corp", issuer_ticker: "BETA")
    create(:insider_transaction, filing: older, insider_cik:, insider_name: "Jane Doe",
                                 transaction_code: "P", shares: 200, price: 10)

    activity = described_class.new(insider_cik:, as_of:).issuer_activity(days: 365)

    expect(activity).to include(
      include("issuer_cik" => "0000000123", "issuer_ticker" => "ACME", "purchase_count" => 1,
              "sale_count" => 1, "purchase_value" => BigDecimal("12500"))
    )
    expect(activity).not_to include(include("issuer_cik" => "0000000457"))
  end

  it "classifies stored 10b5-1 footnotes on transaction rows" do
    ingest_form4(:planned_sales)

    rows = described_class.new(insider_cik: "0001489550", as_of: as_of).transactions

    expect(rows).to all(include(
      "plan_status" => "10b5-1 plan disclosed",
      "plan_adoption_date" => Date.new(2026, 5, 19)
    ))
  end
end
