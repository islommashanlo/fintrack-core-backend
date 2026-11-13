# frozen_string_literal: true

module Api
  module V1
    class ScreenerFundsQuery
      def initialize(page:, history:)
        @page, @history = page, history
      end

      def to_sql
        earliest = @history.earliest(as_of: @page.as_of)
        allowed = earliest ? "s.period_of_report >= #{ApplicationRecord.connection.quote(earliest)}::date" : "TRUE"
        targets = <<~SQL
          SELECT f.id AS institutional_filer_id, s.period_of_report FROM fund_screen s
          INNER JOIN institutional_filers f ON f.cik = s.cik WHERE #{allowed}
        SQL
        bounds = InstitutionalHoldingsQuery::BOUNDS.keys.index_with { |key| @page.bound(key) }
        turnover = FundTurnoverSql.new(periods: targets, bounds:, as_of: @page.as_of)
        <<~SQL
          WITH fund_screen AS (#{portfolio_sql}), turnover AS (#{turnover.to_sql})
          SELECT s.*, t.turnover_percent AS reported_allocation_turnover_percent,
            NOT (#{allowed}) AS turnover_history_restricted,
            (TO_JSONB(t) || JSONB_BUILD_OBJECT('turnover_percent', t.turnover_percent::text)) AS turnover_record
          FROM fund_screen s INNER JOIN institutional_filers f ON f.cik = s.cik
          LEFT JOIN turnover t ON t.institutional_filer_id = f.id
        SQL
      end

      private

      def portfolio_sql
        scope = InstitutionalReportScope.new(as_of: @page.as_of, max_report_id: @page.bound("reports"),
          max_filing_id: @page.bound("filings"))
        <<~SQL
          WITH visible AS (#{scope.visible_reports.to_sql}), effective AS (
            SELECT v.* FROM visible v WHERE v.id IN (#{scope.effective_reports.select(:id).to_sql})
          ), latest AS (
            SELECT DISTINCT ON (institutional_filer_id) institutional_filer_id, period_of_report, filing_id, known_filed_at
            FROM visible ORDER BY institutional_filer_id, period_of_report DESC, known_filed_at DESC, known_accession DESC
          ), reports AS (
            SELECT e.*, h.row_count, h.normalized_total,
              (e.suspect OR e.table_entry_total IS NULL OR e.table_entry_total <> h.row_count
                OR e.table_value_total IS NULL OR e.table_value_total <> h.reported_total OR h.row_suspect) AS report_suspect,
              h.values_complete
            FROM effective e CROSS JOIN LATERAL (
              SELECT COUNT(*) AS row_count, COALESCE(SUM(value_reported), 0) AS reported_total,
                COALESCE(SUM(value_usd), 0) AS normalized_total,
                COALESCE(BOOL_OR(suspect OR cusip IS NULL OR cusip !~ '^[0-9A-Z]{9}$' OR shares <= 0
                  OR share_type NOT IN ('SH', 'PRN') OR (put_call IS NOT NULL AND put_call NOT IN ('PUT', 'CALL'))
                  OR shares::text IN ('NaN', 'Infinity', '-Infinity') OR value_reported < 0
                  OR value_reported::text IN ('NaN', 'Infinity', '-Infinity')), FALSE) AS row_suspect,
                COALESCE(BOOL_AND(value_usd IS NOT NULL AND value_usd >= 0
                  AND value_usd::text NOT IN ('NaN', 'Infinity', '-Infinity')
                  AND e.cover_value_unit IS NOT NULL AND value_unit = e.cover_value_unit AND value_unit IN ('whole_dollars', 'thousands')
                  AND value_usd = value_reported * CASE value_unit WHEN 'whole_dollars' THEN 1 WHEN 'thousands' THEN 1000 END), TRUE) AS values_complete
              FROM institutional_holdings WHERE institutional_report_id = e.id AND id <= #{@page.bound('holdings')}
            ) h
          ), metrics AS (
            SELECT institutional_filer_id, period_of_report, SUM(row_count)::bigint AS holding_row_count,
              ARRAY_AGG(id) AS report_ids, COUNT(*) AS source_filing_count,
              BOOL_OR(report_suspect OR NOT values_complete) AS suspect,
              CASE WHEN BOOL_AND(NOT report_suspect AND values_complete) THEN SUM(normalized_total) END AS portfolio_value_usd
            FROM reports GROUP BY institutional_filer_id, period_of_report
          )
          SELECT f.cik AS event_key, f.cik, f.name, latest.filing_id AS primary_filing_id,
            latest.known_filed_at AS last_filed_at, latest.known_filed_at::date AS last_filed_on, latest.period_of_report,
            m.holding_row_count, positions.position_count, m.portfolio_value_usd, m.suspect,
            COALESCE(m.source_filing_count, 0) AS source_filing_count
          FROM institutional_filers f INNER JOIN latest ON latest.institutional_filer_id = f.id
          LEFT JOIN metrics m ON m.institutional_filer_id = f.id AND m.period_of_report = latest.period_of_report
          LEFT JOIN LATERAL (
            SELECT COUNT(DISTINCT (cusip, COALESCE(put_call, ''), share_type)) AS position_count
            FROM institutional_holdings WHERE institutional_report_id = ANY(m.report_ids) AND id <= #{@page.bound('holdings')}
              AND cusip ~ '^[0-9A-Z]{9}$'
          ) positions ON m.report_ids IS NOT NULL
          WHERE f.id <= #{@page.bound('funds')}
        SQL
      end
    end
  end
end
