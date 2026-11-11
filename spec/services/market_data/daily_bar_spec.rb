# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::DailyBar do
  it "retains exact decimals and integral volumes without binary floating point" do
    row = market_bars.first
    expect(row.open).to eq(BigDecimal("12.1234567890123456789"))
    expect(row.volume).to eq(BigDecimal("12345678901234567890"))
    expect(market_bars.second.volume).to eq(0)
  end

  it "rejects coerced, nonfinite, negative or incomplete OHLCV" do
    [ { open: 12.1 }, { open: "" }, { open: "bad" }, { open: nil }, { open: true },
      { open: BigDecimal("NaN") }, { high: BigDecimal("Infinity") },
      { volume: "1.5" }, { volume: -1 }, { low: "0" }, { high: "1" },
      { low: "100" }, { session_date: "2026-11-05" }, { session_date: Time.utc(2026, 11, 5) } ].each do |change|
      expect { described_class.new(**market_bars.first.to_h.merge(change)) }
        .to raise_error(MarketData::Provider::InvalidResponse)
    end
  end
end
