# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenfigiResponseParser do
  it "returns mapped security fields for each requested CUSIP" do
    results = described_class.parse(
      cusips: [ "037833100" ],
      body: [
        { "data" => [
          {
            "figi" => "BBG000B9XRY4", "ticker" => "AAPL", "name" => "APPLE INC",
            "securityType" => "Common Stock", "marketSector" => "Equity", "exchCode" => "US",
            "shareClassFIGI" => "BBG001S5N8V8", "compositeFIGI" => "BBG000B9XRY4"
          }
        ] }
      ].to_json
    )

    expect(results).to contain_exactly(
      have_attributes(
        cusip: "037833100", status: "mapped", error: nil,
        matches: contain_exactly(
          have_attributes(figi: "BBG000B9XRY4", ticker: "AAPL", name: "APPLE INC", exchange_code: "US")
        )
      )
    )
  end

  it "preserves an explicit no-match result" do
    result = described_class.parse(
      cusips: [ "999999999" ], body: [ { "error" => "No identifier found." } ].to_json
    ).sole

    expect(result).to have_attributes(cusip: "999999999", status: "unmapped", matches: [], error: "No identifier found.")
  end

  it "rejects a response whose result count does not match the request" do
    expect { described_class.parse(cusips: [ "037833100" ], body: "[]") }
      .to raise_error(described_class::MalformedError, /length/)
  end
end
