# frozen_string_literal: true

module Api
  module V1
    # Calculate the full effective portfolio before filtering or paging its rows.
    class FundPortfolioQuery
      Result = Data.define(:meta, :positions)

      def initialize(page:, reports:, fund:, period:)
        @page, @reports, @fund, @period = page, reports, fund, period
      end

      def call(holdings)
        visible = @reports.visible_reports.where(institutional_filer_id: @fund.id, period_of_report: @period)
        effective = @reports.effective_reports.where(institutional_filer_id: @fund.id, period_of_report: @period)
        ids = holdings.map(&:id)
        row = CursorPage.sql_rows(<<~SQL).first
          WITH visible AS (#{visible.to_sql}), effective AS (#{effective.to_sql}),
          checks AS (#{InstitutionalReportChecks.sql(max_holding_id: @page.bound('holdings'))}),
          coverage AS (
            SELECT COUNT(*) AS report_count, ARRAY_AGG(e.id ORDER BY e.id) AS report_ids,
              ARRAY_AGG(e.id ORDER BY e.id) FILTER (WHERE (c.structure_complete AND c.values_complete) IS NOT TRUE) AS incomplete_report_ids,
              COUNT(*) > 0 AND COALESCE(BOOL_AND(COALESCE(c.structure_complete AND c.values_complete, false)), false) AS complete
            FROM effective e INNER JOIN checks c ON c.id = e.id
          ), lines AS (
            SELECT h.* FROM institutional_holdings h INNER JOIN effective e ON e.id = h.institutional_report_id
            WHERE h.id <= #{@page.bound('holdings')}
          ), positions AS (
            SELECT h.cusip, h.put_call, h.share_type, COUNT(*) AS row_count,
              CASE WHEN COUNT(*) = COUNT(*) FILTER (WHERE h.value_usd >= 0
                AND h.value_usd::text NOT IN ('NaN', 'Infinity', '-Infinity')) THEN SUM(h.value_usd) END AS value_usd
            FROM lines h WHERE #{InstitutionalHoldingKey::VALID_SQL}
            GROUP BY h.cusip, h.put_call, h.share_type
          ), totals AS (
            SELECT COUNT(*) AS holding_row_count,
              SUM(value_usd) FILTER (WHERE value_usd >= 0 AND value_usd::text NOT IN ('NaN', 'Infinity', '-Infinity')) AS known_value_usd
            FROM lines
          ), ranked AS (
            SELECT p.*, CASE WHEN c.complete THEN RANK() OVER (ORDER BY p.value_usd DESC NULLS LAST) END AS position_rank,
              CASE WHEN c.complete AND t.known_value_usd > 0 THEN p.value_usd * 100 / t.known_value_usd END AS weight_percent
            FROM positions p CROSS JOIN coverage c CROSS JOIN totals t
          )
          SELECT c.complete, c.report_count, COALESCE(c.report_ids, '{}'::bigint[]) AS report_ids,
            COALESCE(c.incomplete_report_ids, '{}'::bigint[]) AS incomplete_report_ids, t.holding_row_count,
            (SELECT COUNT(*) FROM positions) AS position_count, t.known_value_usd,
            CASE WHEN c.complete THEN COALESCE(t.known_value_usd, 0) END AS total_value_usd,
            (SELECT COALESCE(jsonb_object_agg(h.id::text, jsonb_build_object(
              'row_count', p.row_count, 'value_usd', p.value_usd::text,
              'weight_percent', p.weight_percent::text, 'rank', p.position_rank)), '{}'::jsonb)
              FROM lines h INNER JOIN ranked p ON p.cusip = h.cusip AND p.put_call IS NOT DISTINCT FROM h.put_call
                AND p.share_type = h.share_type
              WHERE h.id IN (#{ids.empty? ? 'NULL' : ids.join(',')})) AS positions
          FROM coverage c CROSS JOIN totals t
        SQL
        Result.new(meta: row.except("positions"), positions: row.fetch("positions"))
      end
    end
  end
end
