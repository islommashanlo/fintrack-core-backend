# frozen_string_literal: true

require "rails_helper"

RSpec.describe CusipSecurityMappingIngestor do
  let(:now) { Time.utc(2026, 10, 2, 20, 0) }
  let(:match) do
    OpenfigiResponseParser::Match.new(
      figi: "BBG000B9XRY4",
      ticker: "AAPL",
      name: "APPLE INC",
      security_type: "Common Stock",
      market_sector: "Equity",
      exchange_code: "US",
      share_class_figi: "BBG001S5N8V8",
      composite_figi: "BBG000B9XRY4"
    )
  end

  it "stores mapped and unmapped results separately from the holding rows" do
    results = [
      OpenfigiResponseParser::Result.new(cusip: "037833100", status: "mapped", matches: [ match ], error: nil),
      OpenfigiResponseParser::Result.new(
        cusip: "999999999", status: "unmapped", matches: [], error: "No identifier found."
      )
    ]

    expect { described_class.call(results, now:) }.to change(CusipSecurityMapping, :count).by(2)
    expect(Security.sole).to have_attributes(figi: "BBG000B9XRY4", ticker: "AAPL")
    expect(CusipSecurityMapping.find_by!(cusip: "037833100")).to have_attributes(status: "mapped", result_seq: 1)
    expect(CusipSecurityMapping.find_by!(cusip: "999999999")).to have_attributes(
      status: "unmapped", security_id: nil, error: "No identifier found."
    )
  end

  it "marks previous results stale and remains idempotent on repeat" do
    result = OpenfigiResponseParser::Result.new(cusip: "037833100", status: "mapped", matches: [ match ], error: nil)

    described_class.call([ result ], now:)
    described_class.call([ result ], now: now + 1.hour)

    expect(Security.count).to eq(1)
    expect(CusipSecurityMapping.count).to eq(1)
    expect(CusipSecurityMapping.sole).to have_attributes(status: "mapped", first_seen_at: now, last_checked_at: now + 1.hour)
  end

  it "keeps multiple OpenFIGI matches as ambiguous" do
    second = match.with(figi: "BBG000B9XRY5", ticker: "APPL")
    result = OpenfigiResponseParser::Result.new(
      cusip: "037833100", status: "mapped", matches: [ match, second ], error: nil
    )

    described_class.call([ result ], now:)

    expect(CusipSecurityMapping.where(cusip: "037833100").pluck(:status, :result_seq))
      .to contain_exactly([ "ambiguous", 1 ], [ "ambiguous", 2 ])
  end
end
