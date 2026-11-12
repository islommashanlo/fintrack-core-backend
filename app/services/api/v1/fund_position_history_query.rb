# frozen_string_literal: true

module Api
  module V1
    class FundPositionHistoryQuery
      SORTS = { "period" => "institutional_reports.period_of_report" }.freeze

      def initialize(fund:, page:, filters:, history:)
        @fund, @page, @filters, @history = fund, page, filters, history
      end

      def call
        period = @filters["period"] && Date.iso8601(@filters["period"])
        @history.check!(period, as_of: @page.as_of)
        scope = InstitutionalReport.from("(#{timeline_sql}) institutional_reports")
        scope = scope.where(period_of_report: period) if period
        @history.preview(page: @page, scope:, allowed_scope: @history.reports(scope, as_of: @page.as_of))
      end

      def self.sources(records)
        InstitutionalReport.where(id: records.flat_map { |row| row["source_ids"] }).includes(:filing).index_by(&:id)
      end

      private

      def timeline_sql
        reports = InstitutionalReportScope.new(as_of: @page.as_of, max_report_id: @page.bound("reports"), max_filing_id: @page.bound("filings"))
        visible = reports.visible_reports.where(institutional_filer_id: @fund.id)
        effective = reports.effective_reports.where(institutional_filer_id: @fund.id)
        sql = FundPortfolioSql.new(visible:, effective:, periods: "SELECT DISTINCT period_of_report FROM visible",
          max_holding_id: @page.bound("holdings"))
        ApplicationRecord.sanitize_sql([ <<~SQL, cusip: @filters.fetch("cusip"), put_call: @filters["put_call"], share_type: @filters.fetch("share_type", "SH") ])
          WITH #{sql.ctes}, source_reports AS (
            SELECT v.* FROM visible v WHERE v.id IN (SELECT id FROM effective)
              OR NOT EXISTS (SELECT 1 FROM effective e WHERE e.period_of_report = v.period_of_report)
          ), contexts AS (
            SELECT period_of_report, ARRAY_AGG(id ORDER BY known_filed_at DESC, known_accession DESC) AS source_ids
            FROM source_reports GROUP BY period_of_report
          )
          SELECT s.source_ids[1] AS id, c.period_of_report, s.source_ids,
            :cusip::text AS cusip, :put_call::text AS put_call, :share_type::text AS share_type,
            CASE WHEN p.cusip IS NOT NULL THEN 'reported' WHEN c.complete THEN 'not_reported' ELSE 'unknown' END AS status,
            #{FundPortfolioSql.metadata_json('c')} AS portfolio,
            CASE WHEN p.cusip IS NOT NULL THEN jsonb_build_object('row_count', p.row_count,
              'issuer_name', p.issuer_name, 'shares_reported', p.shares_reported::text,
              'value_usd', p.value_usd::text, 'weight_percent', p.weight_percent::text, 'rank', p.position_rank) END AS position
          FROM portfolios c INNER JOIN contexts s USING (period_of_report)
          LEFT JOIN ranked p ON p.period_of_report = c.period_of_report AND p.cusip = :cusip
            AND p.put_call IS NOT DISTINCT FROM :put_call::text AND p.share_type = :share_type
        SQL
      end
    end
  end
end
