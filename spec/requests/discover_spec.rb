# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Discover" do
  let(:search) { instance_double(DiscoverySearch) }

  before do
    allow(DiscoverySearch).to receive(:new).with(query: "acme").and_return(search)
    allow(search).to receive(:institutions).and_return([
      { "name" => "Acme Capital", "cik" => "0000000001", "reports" => 4,
        "latest_period" => Date.new(2026, 6, 30) }
    ])
    allow(search).to receive(:insiders).and_return([
      { "insider_name" => "Jane Doe", "insider_cik" => "0000000002", "purchases" => 3, "issuers" => 2 }
    ])
    allow(search).to receive(:issuers).and_return([
      { "issuer_ticker" => "ACME", "issuer_name" => "Acme Corp", "purchases" => 5, "insiders" => 2 }
    ])
  end

  it "searches the covered institutions, insiders, and issuers" do
    get discover_path, params: { q: "acme" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Acme Capital", "Jane Doe", "Acme Corp", "Data from public SEC filings")
  end
end
