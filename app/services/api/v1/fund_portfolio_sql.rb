# frozen_string_literal: true

module Api
  module V1
    # The same report checks and per-period denominators serve holdings and history.
    class FundPortfolioSql
      def initialize(visible:, effective:, periods:, max_holding_id:)
        @visible, @effective, @periods, @max_holding_id = visible, effective, periods, max_holding_id
      end

      def ctes
        <<~SQL
          visible AS (#{@visible.to_sql}), effective AS (#{@effective.to_sql}), periods AS (#{@periods}),
          checks AS (#{InstitutionalReportChecks.sql(max_holding_id: @max_holding_id)}),
          coverage AS (
            SELECT d.period_of_report, COUNT(e.id) AS report_count, ARRAY_AGG(e.id ORDER BY e.id) FILTER (WHERE e.id IS NOT NULL) AS report_ids,
              ARRAY_AGG(e.id ORDER BY e.id) FILTER (WHERE e.id IS NOT NULL AND (c.structure_complete AND c.values_complete) IS NOT TRUE) AS incomplete_report_ids,
              COUNT(e.id) > 0 AND COALESCE(BOOL_AND(COALESCE(c.structure_complete AND c.values_complete, false)), false) AS complete
            FROM periods d LEFT JOIN effective e USING (period_of_report) LEFT JOIN checks c ON c.id = e.id
            GROUP BY d.period_of_report
          ), lines AS (
            SELECT h.*, e.period_of_report FROM institutional_holdings h INNER JOIN effective e ON e.id = h.institutional_report_id
            WHERE h.id <= #{@max_holding_id}
          ), positions AS (
            SELECT h.period_of_report, h.cusip, h.put_call, h.share_type, COUNT(*) AS row_count,
              MIN(h.name_of_issuer) AS issuer_name,
              CASE WHEN COUNT(*) = COUNT(*) FILTER (WHERE h.shares::text NOT IN ('NaN', 'Infinity', '-Infinity')) THEN SUM(h.shares) END AS shares_reported,
              CASE WHEN COUNT(*) = COUNT(*) FILTER (WHERE h.value_usd >= 0
                AND h.value_usd::text NOT IN ('NaN', 'Infinity', '-Infinity')) THEN SUM(h.value_usd) END AS value_usd
            FROM lines h WHERE #{InstitutionalHoldingKey::VALID_SQL}
            GROUP BY h.period_of_report, h.cusip, h.put_call, h.share_type
          ), totals AS (
            SELECT period_of_report, COUNT(*) AS holding_row_count,
              SUM(value_usd) FILTER (WHERE value_usd >= 0 AND value_usd::text NOT IN ('NaN', 'Infinity', '-Infinity')) AS known_value_usd
            FROM lines GROUP BY period_of_report
          ), portfolios AS (
            SELECT c.period_of_report, c.complete, c.report_count, COALESCE(c.report_ids, '{}'::bigint[]) AS report_ids,
              COALESCE(c.incomplete_report_ids, '{}'::bigint[]) AS incomplete_report_ids,
              COALESCE(t.holding_row_count, 0) AS holding_row_count,
              (SELECT COUNT(*) FROM positions p WHERE p.period_of_report = c.period_of_report) AS position_count,
              t.known_value_usd, CASE WHEN c.complete THEN COALESCE(t.known_value_usd, 0.0) END AS total_value_usd
            FROM coverage c LEFT JOIN totals t USING (period_of_report)
          ), ranked AS (
            SELECT p.*, CASE WHEN c.complete THEN RANK() OVER (PARTITION BY p.period_of_report ORDER BY p.value_usd DESC NULLS LAST) END AS position_rank,
              CASE WHEN c.complete AND c.total_value_usd > 0 THEN p.value_usd * 100 / c.total_value_usd END AS weight_percent
            FROM positions p INNER JOIN portfolios c USING (period_of_report)
          )
        SQL
      end

      def self.metadata_json(name)
        <<~SQL.squish
          jsonb_build_object('complete', #{name}.complete, 'report_count', #{name}.report_count,
            'report_ids', #{name}.report_ids, 'incomplete_report_ids', #{name}.incomplete_report_ids,
            'holding_row_count', #{name}.holding_row_count, 'position_count', #{name}.position_count,
            'known_value_usd', #{name}.known_value_usd::text, 'total_value_usd', #{name}.total_value_usd::text)
        SQL
      end
    end
  end
end
