# frozen_string_literal: true

module Api
  module V1
    # Unique targets supply a fund and selected quarter; all adjacent comparisons share one query.
    class FundTurnoverSql
      def initialize(periods:, bounds:, as_of:)
        @periods, @bounds, @as_of = periods, bounds, as_of
      end

      def to_sql
        ids = InstitutionalReport.where(<<~SQL.squish).select(:id)
          EXISTS (SELECT 1 FROM turnover_quarters q
            WHERE q.institutional_filer_id = institutional_reports.institutional_filer_id
              AND q.period_of_report = institutional_reports.period_of_report)
        SQL
        reports = InstitutionalReportScope.new(as_of: @as_of, max_report_id: @bounds.fetch("reports"),
          max_filing_id: @bounds.fetch("filings"), report_ids: ids)
        <<~SQL
          WITH turnover_targets AS (#{@periods}), turnover_quarters AS (
            SELECT institutional_filer_id, period_of_report FROM turnover_targets
            UNION SELECT institutional_filer_id, DATE_TRUNC('quarter', period_of_report)::date - 1 FROM turnover_targets
          ), visible AS (#{reports.visible_reports.to_sql}), effective AS (#{reports.effective_reports.to_sql}),
          checks AS (#{InstitutionalReportChecks.sql(max_holding_id: @bounds.fetch('holdings'))}),
          observed AS (
            SELECT institutional_filer_id, period_of_report, COUNT(*) AS report_count,
              ARRAY_AGG(id ORDER BY known_filed_at DESC, known_accession DESC) AS report_ids
            FROM visible GROUP BY institutional_filer_id, period_of_report
          ), coverage AS (
            SELECT q.institutional_filer_id, q.period_of_report, COUNT(e.id) AS report_count,
              COALESCE(ARRAY_AGG(e.id ORDER BY e.id) FILTER (WHERE e.id IS NOT NULL), '{}'::bigint[]) AS report_ids,
              COALESCE(ARRAY_AGG(e.id ORDER BY e.id) FILTER (WHERE e.id IS NOT NULL
                AND (c.structure_complete AND c.values_complete) IS NOT TRUE), '{}'::bigint[]) AS incomplete_report_ids,
              COUNT(e.id) > 0 AND COALESCE(BOOL_AND(COALESCE(c.structure_complete AND c.values_complete, false)), false) AS complete
            FROM turnover_quarters q LEFT JOIN effective e USING (institutional_filer_id, period_of_report)
            LEFT JOIN checks c ON c.id = e.id GROUP BY q.institutional_filer_id, q.period_of_report
          ), lines AS (
            SELECT h.*, e.institutional_filer_id, e.period_of_report
            FROM institutional_holdings h INNER JOIN effective e ON e.id = h.institutional_report_id
            WHERE h.id <= #{@bounds.fetch('holdings')}
          ), positions AS (
            SELECT h.institutional_filer_id, h.period_of_report, h.cusip, h.put_call, h.share_type,
              CASE WHEN COUNT(*) = COUNT(*) FILTER (WHERE h.value_usd >= 0
                AND h.value_usd::text NOT IN ('NaN', 'Infinity', '-Infinity')) THEN SUM(h.value_usd) END AS value_usd
            FROM lines h WHERE #{InstitutionalHoldingKey::VALID_SQL}
            GROUP BY h.institutional_filer_id, h.period_of_report, h.cusip, h.put_call, h.share_type
          ), position_counts AS (
            SELECT institutional_filer_id, period_of_report, COUNT(*) AS position_count
            FROM positions GROUP BY institutional_filer_id, period_of_report
          ), totals AS (
            SELECT institutional_filer_id, period_of_report, COUNT(*) AS holding_row_count,
              SUM(value_usd) FILTER (WHERE value_usd >= 0 AND value_usd::text NOT IN ('NaN', 'Infinity', '-Infinity')) AS known_value_usd
            FROM lines GROUP BY institutional_filer_id, period_of_report
          ), portfolios AS (
            SELECT c.*, COALESCE(t.holding_row_count, 0) AS holding_row_count, COALESCE(p.position_count, 0) AS position_count,
              t.known_value_usd, CASE WHEN c.complete THEN COALESCE(t.known_value_usd, 0.0) END AS total_value_usd
            FROM coverage c LEFT JOIN totals t USING (institutional_filer_id, period_of_report)
            LEFT JOIN position_counts p USING (institutional_filer_id, period_of_report)
          ), current_positions AS (
            SELECT p.*, t.period_of_report AS comparison_period FROM turnover_targets t
            INNER JOIN positions p USING (institutional_filer_id, period_of_report)
          ), prior_positions AS (
            SELECT p.*, t.period_of_report AS comparison_period FROM turnover_targets t
            INNER JOIN positions p ON p.institutional_filer_id = t.institutional_filer_id
              AND p.period_of_report = DATE_TRUNC('quarter', t.period_of_report)::date - 1
          ), deltas AS (
            SELECT COALESCE(c.institutional_filer_id, p.institutional_filer_id) AS institutional_filer_id,
              COALESCE(c.comparison_period, p.comparison_period) AS period_of_report,
              c.value_usd AS current_value, p.value_usd AS prior_value
            FROM current_positions c FULL OUTER JOIN prior_positions p
              ON p.institutional_filer_id = c.institutional_filer_id AND p.comparison_period = c.comparison_period
              AND p.cusip = c.cusip AND p.put_call IS NOT DISTINCT FROM c.put_call AND p.share_type = c.share_type
          ), movements AS (
            SELECT d.institutional_filer_id, d.period_of_report,
              SUM(ABS(COALESCE(d.current_value, 0) * p.total_value_usd - COALESCE(d.prior_value, 0) * c.total_value_usd)) AS numerator
            FROM deltas d INNER JOIN portfolios c USING (institutional_filer_id, period_of_report)
            INNER JOIN portfolios p ON p.institutional_filer_id = d.institutional_filer_id
              AND p.period_of_report = DATE_TRUNC('quarter', d.period_of_report)::date - 1
            GROUP BY d.institutional_filer_id, d.period_of_report
          ), inputs AS (
            SELECT t.institutional_filer_id, t.period_of_report,
              DATE_TRUNC('quarter', t.period_of_report)::date - 1 AS prior_period_of_report,
              #{FundPortfolioSql.metadata_json('c')} AS current_portfolio, #{FundPortfolioSql.metadata_json('p')} AS prior_portfolio,
              CASE WHEN c.report_count > 0 THEN c.report_ids ELSE COALESCE(oc.report_ids, '{}'::bigint[]) END AS current_source_ids,
              CASE WHEN p.report_count > 0 THEN p.report_ids ELSE COALESCE(op.report_ids, '{}'::bigint[]) END AS prior_source_ids,
              CASE
                WHEN oc.report_count IS NULL THEN 'no_current_report'
                WHEN t.period_of_report > #{ApplicationRecord.connection.quote(@as_of.to_date)}::date THEN 'future_report_period'
                WHEN op.report_count IS NULL THEN 'no_prior_report'
                WHEN c.report_count = 0 THEN 'no_effective_current_holdings'
                WHEN p.report_count = 0 THEN 'no_effective_prior_holdings'
                WHEN NOT c.complete THEN 'incomplete_current_portfolio'
                WHEN NOT p.complete THEN 'incomplete_prior_portfolio'
                WHEN c.total_value_usd = 0 THEN 'zero_current_portfolio_value'
                WHEN p.total_value_usd = 0 THEN 'zero_prior_portfolio_value'
              END AS unavailable_reason,
              CASE WHEN c.complete AND p.complete AND c.total_value_usd > 0 AND p.total_value_usd > 0
                AND t.period_of_report <= #{ApplicationRecord.connection.quote(@as_of.to_date)}::date
                THEN m.numerator * 50 / (c.total_value_usd * p.total_value_usd) END AS turnover_percent
            FROM turnover_targets t INNER JOIN portfolios c USING (institutional_filer_id, period_of_report)
            INNER JOIN portfolios p ON p.institutional_filer_id = t.institutional_filer_id
              AND p.period_of_report = DATE_TRUNC('quarter', t.period_of_report)::date - 1
            LEFT JOIN observed oc ON oc.institutional_filer_id = t.institutional_filer_id AND oc.period_of_report = t.period_of_report
            LEFT JOIN observed op ON op.institutional_filer_id = t.institutional_filer_id AND op.period_of_report = p.period_of_report
            LEFT JOIN movements m ON m.institutional_filer_id = t.institutional_filer_id AND m.period_of_report = t.period_of_report
          ), primary_sources AS (
            SELECT DISTINCT ON (i.institutional_filer_id, i.period_of_report) i.institutional_filer_id, i.period_of_report, v.id
            FROM inputs i CROSS JOIN LATERAL UNNEST(i.current_source_ids || i.prior_source_ids) source(id)
            INNER JOIN visible v ON v.id = source.id
            ORDER BY i.institutional_filer_id, i.period_of_report, v.known_filed_at DESC, v.known_accession DESC
          ) SELECT inputs.*, s.id AS primary_report_id FROM inputs
          LEFT JOIN primary_sources s USING (institutional_filer_id, period_of_report)
        SQL
      end
    end
  end
end
