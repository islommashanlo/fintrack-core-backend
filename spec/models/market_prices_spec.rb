# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Market-price storage" do
  let(:series) { price_series }
  let(:now) { Time.utc(2026, 11, 10, 12) }

  def row_attributes
    market_bars.first.to_h.merge(price_series_id: series.id, observed_at: now, created_at: now, updated_at: now)
  end

  it "enforces natural-key uniqueness for series and daily rows in the database" do
    duplicate = series.attributes.except("id")
    expect { PriceSeries.insert_all!([ duplicate ]) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects duplicate dates in the database even when model validation is bypassed" do
    PriceDaily.insert_all!([ row_attributes ])
    expect { PriceDaily.insert_all!([ row_attributes ]) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects nonfinite prices through the database constraint" do
    expect { PriceDaily.insert_all!([ row_attributes.merge(high: BigDecimal("Infinity")) ]) }
      .to raise_error(ActiveRecord::StatementInvalid, /prices_daily_ohlcv/)
  end

  it "rejects invalid ranges and fractional volume at the model boundary" do
    row = PriceDaily.new(row_attributes.except(:created_at, :updated_at))
    expect(row).to be_valid
    row.high = 1
    expect(row).not_to be_valid
    row.high = 15
    row.volume = BigDecimal("1.5")
    expect(row).not_to be_valid
  end

  it "prevents series identity edits and deletion of referenced source data" do
    MarketData::Ingest.call(series:, bars: market_bars.first(1), observed_at: now)
    expect { series.update!(currency: "EUR") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { series.prices_daily.sole.update!(close: "14") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { series.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
    expect { series.security.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
  end
end
