# frozen_string_literal: true

module Api
  module V1
    class ScreenerResultSerializer
      def initialize(rows:, entity:, as_of:, window_days: nil)
        @entity = entity
        @as_of = as_of
        @window_days = window_days
        @filings = Filing.where(id: rows.map { |row| row.fetch("primary_filing_id") }).index_by(&:id)
      end

      def render(row)
        filing = @filings.fetch(row.fetch("primary_filing_id"))
        metrics = ScreenerDefinition::FIELDS.fetch(@entity).keys - %w[name cik ticker last_filed_on period_of_report]
        FilingProvenance.render(filing, as_of: @as_of).merge(
          entity: @entity, cik: row.fetch("cik"), name: row.fetch("name"), ticker: row["ticker"],
          last_filed_at: row.fetch("last_filed_at"), last_filed_on: row.fetch("last_filed_on"),
          period_of_report: row["period_of_report"], window_days: @window_days,
          metrics: row.slice(*metrics), source_filing_count: row.fetch("source_filing_count"),
          latest_role: @entity == "insiders" ? row.slice("latest_role_issuer_cik", "officer_title") : nil
        )
      end
    end
  end
end
