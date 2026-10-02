# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Insider profiles" do
  let!(:transaction) { create(:insider_transaction, insider_cik: "0000000456", insider_name: "Jane Doe") }
  let(:profile) { instance_double(InsiderProfile) }

  before do
    allow(InsiderProfile).to receive(:new).with(insider_cik: "0000000456").and_return(profile)
    allow(profile).to receive(:name).and_return("Jane Doe")
    allow(profile).to receive(:summary).and_return(
      "purchase_count" => 2, "sale_count" => 1, "issuer_count" => 2,
      "purchase_value" => BigDecimal("12500"), "purchases_without_usable_price" => 0,
      "last_filed_at" => transaction.filing.filed_at
    )
    allow(profile).to receive(:transactions).and_return([
      { "issuer_ticker" => "ACME", "issuer_name" => "Acme Corp", "transaction_code" => "P",
        "transaction_date" => Date.new(2026, 9, 28), "filed_at" => transaction.filing.filed_at,
        "shares" => 500, "price" => BigDecimal("25"), "price_suspect" => false,
        "value" => BigDecimal("12500") }
    ])
    allow(profile).to receive(:issuer_activity).and_return([])
  end

  it "shows the insider activity profile" do
    get insider_path("0000000456")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Jane Doe", "Issuer activity", "Transaction history", "Acme Corp",
                                     "Reported purchase value")
  end
end
