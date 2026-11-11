# frozen_string_literal: true

module MarketData
  class Ingest
    class Conflict < StandardError; end
    MAX_BARS = 366
    VALUES = %i[open high low close volume].freeze

    def self.call(series:, bars:, observed_at: Time.current)
      unless bars.is_a?(Array) && bars.size <= MAX_BARS && bars.all? { |bar| bar.is_a?(DailyBar) }
        raise Provider::InvalidResponse, "Expected at most #{MAX_BARS} daily bars"
      end
      dates = bars.map(&:session_date)
      unless dates.uniq.size == dates.size && dates.none? { |date| date > observed_at.to_date }
        raise Provider::InvalidResponse, "Duplicate or future session dates"
      end

      series.with_lock do
        existing = series.prices_daily.where(session_date: dates).index_by(&:session_date)
        rows = bars.filter_map do |bar|
          previous = existing[bar.session_date]
          if previous
            unless VALUES.all? { |field| previous.public_send(field) == bar.public_send(field) }
              raise Conflict, "Stored daily bar differs for #{bar.session_date.iso8601}"
            end
            next
          end
          bar.to_h.merge(price_series_id: series.id, observed_at:, created_at: Time.current, updated_at: Time.current)
        end
        PriceDaily.insert_all!(rows) if rows.any?
        rows.size
      end
    end
  end
end
