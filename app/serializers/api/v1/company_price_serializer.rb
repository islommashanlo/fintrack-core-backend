# frozen_string_literal: true

module Api
  module V1
    class CompanyPriceSerializer
      def self.series(series)
        { id: series.id, security_id: series.security_id, figi: series.security.figi,
          provider: series.provider, provider_symbol: series.provider_symbol,
          currency: series.currency, adjustment: series.adjustment }
      end

      def self.bar(row)
        { session_date: row.session_date, open: row.open.to_s("F"), high: row.high.to_s("F"),
          low: row.low.to_s("F"), close: row.close.to_s("F"), volume: row.volume.to_s("F"),
          observed_at: row.observed_at }
      end

      def self.marker(filing, as_of:)
        FilingProvenance.render(filing, as_of:).merge(marker_date: filing.filed_at.utc.to_date,
          period_of_report: filing.period_of_report, is_amendment: filing.amendment?)
      end
    end
  end
end
