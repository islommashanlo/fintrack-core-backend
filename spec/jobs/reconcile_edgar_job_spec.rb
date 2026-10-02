# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReconcileEdgarJob do
  let(:quarter_url) { "https://www.sec.gov/Archives/edgar/daily-index/2026/QTR3" }

  it "backfills yesterday, as dated in EDGAR's time zone" do
    stub_request(:get, "#{quarter_url}/index.json").to_return(body: edgar_fixture("daily_index_listing.json"))
    stub_request(:get, "#{quarter_url}/master.20260930.idx").to_return(body: edgar_fixture("master.20260930.idx"))

    travel_to(Time.utc(2026, 10, 1, 7, 30)) { described_class.perform_now }

    expect(BackfillRun.sole).to have_attributes(day: Date.new(2026, 9, 30), status: "done", filings_new: 16)
  end
end
