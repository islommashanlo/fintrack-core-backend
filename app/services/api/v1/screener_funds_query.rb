# frozen_string_literal: true

module Api
  module V1
    class ScreenerFundsQuery
      def initialize(page:, history:)
        @page, @history = page, history
      end

      def to_sql
        directory = FundDirectorySql.new(page: @page, history: @history, period: nil, include_turnover: true)
        reports = InstitutionalReportScope.new(as_of: @page.as_of, max_report_id: @page.bound("reports"),
          max_filing_id: @page.bound("filings"),
          report_ids: InstitutionalReport.where("institutional_filer_id <= ?", @page.bound("funds")).select(:id))
        <<~SQL
          WITH directory AS (#{directory.to_sql}), latest AS (
            SELECT DISTINCT ON (institutional_filer_id) institutional_filer_id, period_of_report, filing_id, known_filed_at
            FROM (#{reports.visible_reports.to_sql}) visible
            ORDER BY institutional_filer_id, period_of_report DESC, known_filed_at DESC, known_accession DESC
          )
          SELECT d.cik AS event_key, d.cik, d.name, l.filing_id AS primary_filing_id,
            l.known_filed_at AS last_filed_at, l.known_filed_at::date AS last_filed_on, l.period_of_report,
            CASE WHEN d.effective_report_count > 0 THEN d.holding_row_count END AS holding_row_count,
            d.position_count, d.portfolio_value_usd,
            CASE WHEN d.effective_report_count > 0 THEN NOT d.portfolio_complete END AS suspect,
            d.effective_report_count AS source_filing_count,
            d.portfolio_unavailable_reason AS fund_metrics_unavailable_reason,
            d.reported_allocation_turnover_percent, d.turnover_record,
            d.portfolio_unavailable_reason IS NOT DISTINCT FROM 'history_restricted' AS turnover_history_restricted
          FROM directory d INNER JOIN latest l ON l.institutional_filer_id = d.id
        SQL
      end
    end
  end
end
