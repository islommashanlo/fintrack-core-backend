# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::Ingest do
  let(:series) { price_series }
  let(:observed_at) { Time.utc(2026, 11, 10, 12) }

  it "stores exact OHLCV separately from reported filing prices and is idempotent" do
    reported = create(:insider_transaction, price: "123.456")
    expect(described_class.call(series:, bars: market_bars, observed_at:)).to eq(3)
    original = series.prices_daily.order(:session_date).first.attributes
    expect(original).to include("open" => BigDecimal("12.1234567890123456789"),
                               "volume" => BigDecimal("12345678901234567890"), "observed_at" => observed_at)
    expect(described_class.call(series:, bars: market_bars, observed_at: observed_at + 1.day)).to eq(0)
    expect(series.prices_daily.order(:session_date).first.attributes).to eq(original)
    expect(reported.reload.price).to eq(BigDecimal("123.456"))
  end

  it "rejects the entire batch when a stored bar conflicts without rewriting history" do
    described_class.call(series:, bars: market_bars.first(1), observed_at:)
    conflicting = MarketData::DailyBar.new(**market_bars.first.to_h.merge(close: "14"))
    expect do
      described_class.call(series:, bars: [ market_bars.last, conflicting ], observed_at:)
    end.to raise_error(described_class::Conflict)
    expect(series.prices_daily.count).to eq(1)
    expect(series.prices_daily.sole.close).to eq(BigDecimal("13.75"))
  end

  it "rejects duplicate, future, untyped and oversized batches before inserting" do
    future = MarketData::DailyBar.new(**market_bars.first.to_h.merge(session_date: Date.new(2026, 11, 11)))
    [ market_bars.first(1) * 2, [ future ], [ market_bars.first.to_h ], market_bars * 123, nil ].each do |bars|
      expect { described_class.call(series:, bars:, observed_at:) }.to raise_error(MarketData::Provider::InvalidResponse)
    end
    expect(series.prices_daily).to be_empty
  end

  it "isolates provider, currency, adjustment and stable security identity" do
    variants = [ series, price_series(security: series.security, provider: "another"),
                 price_series(security: series.security, currency: "EUR"),
                 price_series(security: series.security, adjustment: "split_adjusted"), price_series ]
    variants.each { |variant| described_class.call(series: variant, bars: market_bars.first(1), observed_at:) }
    expect(PriceDaily.count).to eq(5)
    series.security.update!(ticker: "CHANGED")
    expect(series.prices_daily.sole.close).to eq(BigDecimal("13.75"))
    expect(series.reload.provider_symbol).to eq("EXAMPLE.X")
  end
end
