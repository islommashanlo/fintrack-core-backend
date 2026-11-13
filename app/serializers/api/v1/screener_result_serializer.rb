# frozen_string_literal: true

module Api
  module V1
    class ScreenerResultSerializer
      def initialize(rows:, entity:, as_of:, window_days: nil)
        @entity = entity
        @as_of = as_of
        @window_days = window_days
        if entity == "funds"
          ids = rows.flat_map do |row|
            turnover = row["turnover_record"]
            row.fetch("fund_source_report_ids") + (turnover ? turnover.fetch("current_source_ids") + turnover.fetch("prior_source_ids") : [])
          end
          @fund_sources = InstitutionalReport.where(id: ids).includes(:filing).index_by(&:id)
          @turnover_context = FundTurnoverSerializer.context
        end
        @filings = Filing.where(id: rows.map { |row| row.fetch("primary_filing_id") }).index_by(&:id)
      end

      def render(row)
        filing = @filings.fetch(row.fetch("primary_filing_id"))
        metrics = ScreenerDefinition::FIELDS.fetch(@entity).keys - %w[name cik ticker last_filed_on period_of_report coverage report_type]
        result = FilingProvenance.render(filing, as_of: @as_of).merge(
          entity: @entity, cik: row.fetch("cik"), name: row.fetch("name"), ticker: row["ticker"],
          last_filed_at: row.fetch("last_filed_at"), last_filed_on: row.fetch("last_filed_on"),
          period_of_report: row["period_of_report"], window_days: @window_days,
          metrics: row.slice(*metrics), source_filing_count: row.fetch("source_filing_count"),
          latest_role: @entity == "insiders" ? row.slice("latest_role_issuer_cik", "officer_title") : nil
        )
        if @entity == "funds"
          result[:reported_allocation_turnover] = turnover(row)
          result[:fund_metrics_unavailable_reason] = row.fetch("fund_metrics_unavailable_reason")
          result[:coverage] = row.fetch("coverage")
          result[:report_types] = row.fetch("report_type")
          result[:report_type_sources] = row.fetch("fund_source_report_ids").map do |id|
            report = @fund_sources.fetch(id)
            FilingProvenance.render(report.filing, as_of: @as_of).merge(report_type: report.report_type)
          end
        end
        result
      end

      private

      def turnover(row)
        if row.fetch("turnover_history_restricted")
          return FundTurnoverSummarySerializer.history_restricted(period: row.fetch("period_of_report"), context: @turnover_context)
        end
        calculation = row["turnover_record"]
        data = FundTurnoverSerializer.render(row: calculation, sources: @fund_sources, period: row.fetch("period_of_report"), as_of: @as_of)
        FundTurnoverSummarySerializer.render(data:, meta: @turnover_context)
      end
    end
  end
end
