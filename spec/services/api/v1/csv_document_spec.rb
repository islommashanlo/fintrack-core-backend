# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::CsvDocument do
  def document(**values)
    described_class.render(dataset: "insider-transactions", rows: [ values ])
  end

  it "writes quoted UTF-8 cells with CRLF records, escaped quotes and preserved embedded newlines" do
    text = document(insider_name: "Doe, \"J\"\r\nZoë", shares: BigDecimal("12.500000000001"), price: nil,
      transaction_date: Date.new(2026, 11, 9), filed_at: Time.utc(2026, 11, 10, 12))
    expect(text).to include('"Doe, ""J""' + "\r\nZoë\"", '"12.500000000001",""', '"2026-11-09"', '"2026-11-10T12:00:00.000000Z"')
    expect(text).to end_with('"Data from public SEC filings. Not investment advice."' + "\r\n")
    expect(text.encoding).to eq(Encoding::UTF_8)
  end

  it "neutralizes text formulas including whitespace/control prefixes without changing typed negative numbers" do
    [ "=1+1", "+1+1", "-1+1", "@SUM(A1)", " \t=1+1", "\uFEFF=1+1", "\n@SUM(A1)", "\tlabel" ].each do |text|
      expect(document(insider_name: text)).to include("\"'#{text}\"")
    end
    expect(document(insider_name: "Normal name", shares: BigDecimal("-1.25"))).to include('"Normal name"', '"-1.25"')
    expect(document(insider_name: "Normal name")).not_to include("'Normal name")
  end

  it "encodes source lists as quoted JSON, with explicit booleans and blank unknown quantities" do
    text = described_class.render(dataset: "fund-changes", rows: [ {
      current_suspect: true, prior_suspect: false, shares_delta: nil,
      current_sources: [ { accession: "0000000001-26-000001" } ], prior_sources: []
    } ])
    expect(text).to include('"true","false","[{""accession"":""0000000001-26-000001""}]","[]"')
  end

  it "returns headers for an empty result and fails before returning an oversized file" do
    text = described_class.render(dataset: "fund-holdings", rows: [])
    expect(text.lines.size).to eq(1)
    expect(text).to include('"value_reported","value_unit","value_usd"')
    stub_const("Api::V1::CsvDocument::MAX_BYTES", 1000)
    expect { document(insider_name: "x" * 1001) }.to raise_error(described_class::TooLarge)
  end

  it "exports nested screener metrics with string keys while preserving typed zero, false and negative decimals" do
    text = described_class.render(dataset: "screener-insiders", rows: [ {
      metrics: { "purchase_count" => 0, "latest_is_director" => false, "net_open_market_value" => BigDecimal("-1.250000000001") },
      latest_role: { "officer_title" => "=SUM(A1)" }
    } ])
    expect(text).to include('"0"', '"false"', '"-1.250000000001"', '"\'=SUM(A1)"')
  end
end
