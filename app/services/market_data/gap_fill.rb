# frozen_string_literal: true

module MarketData
  class GapFill
    Result = Data.define(:requested_from, :requested_to, :inserted_count, :missing_dates)

    def self.call(series:, session_dates:, provider: Provider::Disabled.new, observed_at: nil)
      new(series:, session_dates:, provider:, observed_at:).call
    end

    def initialize(series:, session_dates:, provider:, observed_at:)
      date_ceiling = (observed_at || Time.current).to_date
      unless session_dates.is_a?(Array) && session_dates.size <= Ingest::MAX_BARS &&
             session_dates.all? { |date| date.instance_of?(Date) && date <= date_ceiling }
        raise ArgumentError, "Expected at most #{Ingest::MAX_BARS} nonfuture session dates"
      end
      @dates = session_dates.uniq.sort
      if @dates.any? && (@dates.last - @dates.first).to_i >= Ingest::MAX_BARS
        raise ArgumentError, "Session range exceeds #{Ingest::MAX_BARS} calendar days"
      end
      @series, @provider, @observed_at = series, provider, observed_at
    end

    def call
      missing = missing_dates
      return Result.new(requested_from: nil, requested_to: nil, inserted_count: 0, missing_dates: []) if missing.empty?

      if @provider.is_a?(Provider::Disabled)
        raise Provider::NotConfigured, "No market-data provider is configured"
      end
      unless @provider.key == @series.provider
        raise ArgumentError, "Provider does not match the stored series"
      end
      from, to = missing.first, missing.last
      # Fetch before taking the series lock. Recheck conflicts inside Ingest so
      # overlapping workers cannot silently rewrite each other's observations.
      bars = @provider.daily_bars(series: @series, from:, to:)
      allowed = @dates.select { |date| date.between?(from, to) }
      unless bars.is_a?(Array) && bars.size <= Ingest::MAX_BARS &&
             bars.all? { |bar| bar.is_a?(DailyBar) && allowed.include?(bar.session_date) }
        raise Provider::InvalidResponse, "Provider returned bars outside the requested sessions"
      end
      inserted = Ingest.call(series: @series, bars:, observed_at: @observed_at || Time.current)
      Result.new(requested_from: from, requested_to: to, inserted_count: inserted, missing_dates: missing_dates)
    end

    private

    def missing_dates
      return [] if @dates.empty?

      # A caller supplies sessions from an authoritative calendar; absent bars
      # are unknown, never synthetic zero prices or inferred market holidays.
      dates_sql = @dates.map { |date| PriceDaily.connection.quote(date) }.join(", ")
      sql = PriceDaily.sanitize_sql_array([ <<~SQL, @series.id ])
        SELECT session_date FROM unnest(ARRAY[#{dates_sql}]::date[]) AS expected(session_date)
        WHERE NOT EXISTS (
          SELECT 1 FROM prices_daily p
          WHERE p.price_series_id = ? AND p.session_date = expected.session_date
        ) ORDER BY session_date
      SQL
      PriceDaily.connection.select_values(sql).map { |value| value.is_a?(Date) ? value : Date.iso8601(value) }
    end
  end
end
