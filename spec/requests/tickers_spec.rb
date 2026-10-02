# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ticker profiles" do
  let(:profile) { instance_double(TickerProfile) }

  before do
    allow(TickerProfile).to receive(:new).with(ticker: "ACME").and_return(profile)
    allow(profile).to receive(:issuer).and_return(
      { "issuer_cik" => "0000000123", "issuer_name" => "Acme Corp", "issuer_ticker" => "ACME" }
    )
    allow(profile).to receive(:summary).and_return(
      "purchase_count" => 2, "sale_count" => 1, "insider_count" => 2,
      "purchase_value" => BigDecimal("12500"), "purchases_without_usable_price" => 0,
      "last_filed_at" => Time.zone.parse("2026-10-01 15:00")
    )
    allow(profile).to receive(:transactions).and_return([
      { "insider_name" => "Jane Doe", "insider_cik" => "0000000456", "transaction_code" => "P",
        "transaction_date" => Date.new(2026, 9, 28), "filed_at" => Time.zone.parse("2026-10-01 15:00"),
        "shares" => 500, "price" => BigDecimal("25"), "price_suspect" => false,
        "value" => BigDecimal("12500"), "plan_status" => "10b5-1 plan disclosed" }
    ])
    allow(profile).to receive(:institutional_holdings).and_return([])
    allow(profile).to receive(:institutional_changes).and_return([])
    allow(profile).to receive(:institutional_history).and_return([])
    collisions = instance_double(SmartMoneyCollisions)
    allow(SmartMoneyCollisions).to receive(:new).and_return(collisions)
    allow(collisions).to receive(:matches).and_return([
      { "ticker" => "ACME", "insiders" => 2, "institutions" => 1,
        "latest_insider_filed_at" => Time.zone.parse("2026-10-01 15:00"),
        "latest_institution_filed_at" => Time.zone.parse("2026-08-14 15:00") }
    ])
  end

  it "shows insider activity and the institutional ownership sections" do
    get ticker_path("ACME")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Acme Corp", "Insider activity", "Jane Doe",
                                     "Smart-money overlap",
                                     "Institutional ownership", "Institutional ownership history",
                                     "Institutional ownership changes", "mapped CUSIP", "10b5-1 plan disclosed")
  end
end
