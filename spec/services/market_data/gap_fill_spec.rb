# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::GapFill do
  let(:series) { price_series }
  let(:observed_at) { Time.utc(2026, 11, 10, 12) }
  let(:dates) { market_bars.map(&:session_date) }
  let(:provider) { double("Fixture daily price adapter", key: "fixture", daily_bars: market_bars) }

  it "requests one bounded range for missing sessions, retaining existing bars" do
    MarketData::Ingest.call(series:, bars: market_bars.first(1), observed_at:)
    allow(provider).to receive(:daily_bars).and_return(market_bars.drop(1))
    result = described_class.call(series:, session_dates: dates.reverse * 2, provider:, observed_at:)
    expect(provider).to have_received(:daily_bars).once.with(series:, from: dates.second, to: dates.last)
    expect(result).to have_attributes(inserted_count: 2, missing_dates: [])
    expect(series.prices_daily.order(:session_date).pluck(:session_date)).to eq(dates)
    expect(WebMock).not_to have_requested(:get, /https?:/)
  end

  it "does not invoke any provider for fully stored or empty session lists" do
    MarketData::Ingest.call(series:, bars: market_bars, observed_at:)
    [ dates, [] ].each do |sessions|
      result = described_class.call(series:, session_dates: sessions, observed_at:)
      expect(result).to have_attributes(requested_from: nil, requested_to: nil, inserted_count: 0, missing_dates: [])
    end
  end

  it "records default observation time after fetching rather than backdating availability" do
    travel_to observed_at do
      allow(provider).to receive(:daily_bars) do
        travel 1.minute
        market_bars
      end
      described_class.call(series:, session_dates: dates, provider:)
      expect(series.prices_daily.pluck(:observed_at).uniq).to eq([ observed_at + 1.minute ])
    end
  end

  it "leaves empty and partial responses explicitly missing and eligible for a later fill" do
    allow(provider).to receive(:daily_bars).and_return([], market_bars.first(1), market_bars.drop(1))
    first = described_class.call(series:, session_dates: dates, provider:, observed_at:)
    second = described_class.call(series:, session_dates: dates, provider:, observed_at:)
    third = described_class.call(series:, session_dates: dates, provider:, observed_at:)
    expect(first).to have_attributes(inserted_count: 0, missing_dates: dates)
    expect(second).to have_attributes(inserted_count: 1, missing_dates: dates.drop(1))
    expect(third).to have_attributes(inserted_count: 2, missing_dates: [])
  end

  it "fails closed by default and refuses mismatched provider identities before fetching" do
    expect { described_class.call(series:, session_dates: dates, observed_at:) }
      .to raise_error(MarketData::Provider::NotConfigured)
    allow(provider).to receive(:key).and_return("other")
    expect { described_class.call(series:, session_dates: dates, provider:, observed_at:) }
      .to raise_error(ArgumentError, /Provider does not match/)
    expect(provider).not_to have_received(:daily_bars)
    expect(PriceDaily.count).to eq(0)
  end

  it "rejects unbounded, malformed and future session requests before fetching" do
    [ nil, [ "2026-11-05" ], [ Date.new(2026, 11, 11) ], dates * 123,
      [ Date.new(2024, 1, 1), dates.last ] ].each do |session_dates|
      expect { described_class.call(series:, session_dates:, provider:, observed_at:) }.to raise_error(ArgumentError)
    end
    expect(provider).not_to have_received(:daily_bars)
  end

  it "rejects out-of-range, non-session or untyped bars atomically" do
    weekend = MarketData::DailyBar.new(**market_bars.first.to_h.merge(session_date: Date.new(2026, 11, 7)))
    [ [ market_bars.first, weekend ], [ market_bars.first.to_h ], nil ].each do |response|
      allow(provider).to receive(:daily_bars).and_return(response)
      expect { described_class.call(series:, session_dates: dates, provider:, observed_at:) }
        .to raise_error(MarketData::Provider::InvalidResponse)
    end
    expect(PriceDaily.count).to eq(0)
  end

  it "propagates provider unavailability without recording empty coverage" do
    allow(provider).to receive(:daily_bars).and_raise(MarketData::Provider::Unavailable)
    expect { described_class.call(series:, session_dates: dates, provider:, observed_at:) }
      .to raise_error(MarketData::Provider::Unavailable)
    expect(PriceDaily.count).to eq(0)
  end
end
