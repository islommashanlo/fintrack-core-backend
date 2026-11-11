# frozen_string_literal: true

module MarketPriceFixtures
  def market_bars
    JSON.parse(Rails.root.join("spec/fixtures/market_data/daily_bars.json").read).map do |row|
      values = row.symbolize_keys
      MarketData::DailyBar.new(**values.merge(session_date: Date.iso8601(values.fetch(:session_date))))
    end
  end

  def price_series(security: create(:security), **attributes)
    PriceSeries.create!(security:, provider: "fixture", provider_symbol: "EXAMPLE.X",
                        currency: "USD", adjustment: "unadjusted", **attributes)
  end
end

RSpec.configure do |config|
  config.include MarketPriceFixtures
end
