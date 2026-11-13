# frozen_string_literal: true

module Api
  module V1
    class FundDirectorySql
      def initialize(page:, history:, period:, fund_id: nil, include_turnover: false)
        @page, @history, @period, @fund_id = page, history, period, fund_id
        @include_turnover = include_turnover
      end

      def to_sql
        return portfolio_sql unless @include_turnover

        targets = if @period
          "SELECT id AS institutional_filer_id, #{quote(@period)}::date AS period_of_report FROM directory"
        else
          "SELECT id AS institutional_filer_id, period_of_report FROM directory WHERE period_of_report IS NOT NULL"
        end
        bounds = InstitutionalHoldingsQuery::BOUNDS.keys.index_with { |key| @page.bound(key) }
        turnover = FundTurnoverSql.new(periods: targets, bounds:, as_of: @page.as_of)
        <<~SQL
          WITH directory AS (#{portfolio_sql}), turnover AS (#{turnover.to_sql})
          SELECT d.*, t.turnover_percent AS reported_allocation_turnover_percent, (TO_JSONB(t) || JSONB_BUILD_OBJECT('turnover_percent', t.turnover_percent::text)) AS turnover_record
          FROM directory d LEFT JOIN turnover t ON t.institutional_filer_id = d.id
        SQL
      end

      private

      def portfolio_sql
        reports = InstitutionalReportScope.new(as_of: @page.as_of, max_report_id: @page.bound("reports"), max_filing_id: @page.bound("filings"))
        visible = reports.visible_reports.where("institutional_reports.institutional_filer_id <= ?", @page.bound("funds"))
        visible = visible.where(period_of_report: @period) if @period
        visible = visible.where(institutional_filer_id: @fund_id) if @fund_id
        allowed = @history.earliest(as_of: @page.as_of)
        allowed_sql = allowed ? "l.period_of_report >= #{quote(allowed)}" : "TRUE"
        <<~SQL
          WITH visible AS (#{visible.to_sql}), effective AS (
            SELECT v.* FROM visible v WHERE v.id IN (#{reports.effective_reports.select(:id).to_sql})
          ), checks AS (#{InstitutionalReportChecks.sql(max_holding_id: @page.bound('holdings'))}), latest AS (
            SELECT DISTINCT ON (institutional_filer_id) id, institutional_filer_id, period_of_report, report_type
            FROM visible ORDER BY institutional_filer_id, period_of_report DESC, known_filed_at DESC, known_accession DESC
          ), contexts AS (
            SELECT e.institutional_filer_id, e.period_of_report, COUNT(*) AS report_count,
              ARRAY_AGG(e.id ORDER BY e.known_filed_at DESC, e.known_accession DESC) AS report_ids,
              ARRAY_AGG(DISTINCT e.report_type ORDER BY e.report_type) AS report_types,
              BOOL_AND(COALESCE(c.structure_complete AND c.values_complete, false)) AS complete
            FROM effective e INNER JOIN checks c ON c.id = e.id
            GROUP BY e.institutional_filer_id, e.period_of_report
          ), totals AS (
            SELECT e.institutional_filer_id, e.period_of_report, COUNT(*) AS holding_row_count,
              SUM(h.value_usd) FILTER (WHERE h.value_usd >= 0 AND h.value_usd::text NOT IN ('NaN', 'Infinity', '-Infinity')) AS value_usd,
              COUNT(DISTINCT (h.cusip, h.put_call, h.share_type)) FILTER (WHERE #{InstitutionalHoldingKey::VALID_SQL}) AS position_count
            FROM effective e INNER JOIN institutional_holdings h ON h.institutional_report_id = e.id
            WHERE h.id <= #{@page.bound('holdings')} GROUP BY e.institutional_filer_id, e.period_of_report
          )
          SELECT f.id, f.cik, f.name,
            CASE WHEN #{allowed_sql} THEN l.period_of_report END AS period_of_report,
            CASE WHEN #{allowed_sql} THEN COALESCE(c.complete, false) END AS portfolio_complete,
            CASE WHEN #{allowed_sql} AND c.complete THEN COALESCE(t.value_usd, 0.0) END AS portfolio_value_usd,
            CASE WHEN #{allowed_sql} AND c.complete THEN COALESCE(t.position_count, 0) END AS position_count,
            CASE WHEN #{allowed_sql} THEN COALESCE(t.holding_row_count, 0) END AS holding_row_count,
            CASE WHEN #{allowed_sql} THEN COALESCE(c.report_count, 0) END AS effective_report_count,
            CASE WHEN #{allowed_sql} AND l.id IS NOT NULL THEN COALESCE(c.report_ids, ARRAY[l.id]) ELSE '{}'::bigint[] END AS source_report_ids,
            CASE WHEN #{allowed_sql} AND l.id IS NOT NULL THEN COALESCE(c.report_types, ARRAY[l.report_type]) ELSE '{}'::varchar[] END AS portfolio_report_types,
            CASE WHEN l.id IS NULL THEN 'no_report'
              WHEN NOT (#{allowed_sql}) THEN 'history_restricted'
              WHEN c.report_count IS NULL THEN 'no_effective_holdings'
              WHEN NOT c.complete THEN 'incomplete_report_set' END AS portfolio_unavailable_reason
          FROM institutional_filers f LEFT JOIN latest l ON l.institutional_filer_id = f.id
          LEFT JOIN contexts c ON c.institutional_filer_id = f.id AND c.period_of_report = l.period_of_report
          LEFT JOIN totals t ON t.institutional_filer_id = f.id AND t.period_of_report = l.period_of_report
          WHERE f.id <= #{@page.bound('funds')} #{@fund_id ? "AND f.id = #{quote(@fund_id)}" : ''}
        SQL
      end

      def quote(value) = ApplicationRecord.connection.quote(value)
    end
  end
end
