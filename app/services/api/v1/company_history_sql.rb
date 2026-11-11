# frozen_string_literal: true

module Api
  module V1
    class CompanyHistorySql
      SOURCE_LIMIT = 20
      POSITION_LIMIT = 100

      def initialize(page:, ticker:, filters:)
        @page, @ticker, @filters = page, ticker, filters
        @reports = InstitutionalReportScope.new(as_of: page.as_of, max_report_id: page.bound("reports"),
          max_filing_id: page.bound("filings"), max_holding_id: page.bound("holdings"))
      end

      def mappings
        CusipSecurityMapping.joins(:security).where(status: "mapped")
          .where("UPPER(securities.ticker) = ? AND cusip_security_mappings.id <= ? AND securities.id <= ? AND first_seen_at <= ?",
            @ticker, @page.bound("mappings"), @page.bound("securities"), @page.as_of)
      end

      def coverage
        <<~SQL
          WITH #{inputs}
          SELECT (SELECT COUNT(*) FROM cohort) AS cohort_fund_count,
            (SELECT COUNT(*) FROM mappings) AS mapping_count
        SQL
      end

      def timeline
        <<~SQL
          WITH #{inputs}, #{quarters}, history AS (
            SELECT summary.*, LAG(period_of_report) OVER (ORDER BY period_of_report) AS prior_period,
              LAG(complete) OVER (ORDER BY period_of_report) AS prior_complete,
              LAG(holder_count) OVER (ORDER BY period_of_report) AS prior_holder_count,
              LAG(report_ids) OVER (ORDER BY period_of_report) AS prior_report_ids,
              LAG(source_count) OVER (ORDER BY period_of_report) AS prior_source_count
            FROM summary
          )
          SELECT (period_of_report - DATE '1970-01-01')::bigint AS id,
            history.*, CASE WHEN complete AND prior_complete
              AND prior_period = date_trunc('quarter', period_of_report)::date - 1
              THEN holder_count - prior_holder_count END AS holder_count_delta
          FROM history
        SQL
      end

      private

      def inputs
        <<~SQL
          mappings AS (SELECT DISTINCT cusip FROM (#{mappings.select('cusip_security_mappings.cusip').to_sql}) known),
          visible AS (#{@reports.visible_reports.to_sql}), effective AS (#{@reports.effective_reports.to_sql}),
          valid_lines AS (
            SELECT h.*, r.institutional_filer_id, r.period_of_report, r.suspect AS report_suspect
            FROM effective r INNER JOIN institutional_holdings h ON h.institutional_report_id = r.id
            WHERE h.id <= #{@page.bound('holdings')} AND #{InstitutionalHoldingKey::VALID_SQL}
          ), cohort AS (
            SELECT DISTINCT l.institutional_filer_id FROM valid_lines l WHERE l.cusip IN (SELECT cusip FROM mappings)
          ), contexts AS (
            SELECT r.institutional_filer_id, r.period_of_report, BOOL_OR(r.suspect) AS suspect
            FROM effective r INNER JOIN cohort c ON c.institutional_filer_id = r.institutional_filer_id
            GROUP BY r.institutional_filer_id, r.period_of_report
          ), invalid AS (
            SELECT r.period_of_report, COUNT(*) AS excluded_rows
            FROM effective r INNER JOIN cohort c ON c.institutional_filer_id = r.institutional_filer_id
            INNER JOIN institutional_holdings h ON h.institutional_report_id = r.id
            WHERE h.id <= #{@page.bound('holdings')} AND (#{InstitutionalHoldingKey::VALID_SQL}) IS NOT TRUE
            GROUP BY r.period_of_report
          ), matched AS (
            SELECT l.* FROM valid_lines l WHERE l.cusip IN (SELECT cusip FROM mappings) #{security_filters}
          ), evidence AS (
            SELECT v.* FROM visible v INNER JOIN cohort c ON c.institutional_filer_id = v.institutional_filer_id
            WHERE v.id IN (SELECT id FROM effective) OR v.submission_type = '13F-NT'
              OR (v.amendment_type = 'NEW HOLDINGS' AND NOT EXISTS (
                SELECT 1 FROM contexts x WHERE x.institutional_filer_id = v.institutional_filer_id
                  AND x.period_of_report = v.period_of_report))
          )
        SQL
      end

      def security_filters
        clauses, binds = [], {}
        %w[cusip put_call share_type].each do |key|
          next unless @filters[key]
          clauses << "AND l.#{key} = :#{key}"
          binds[key.to_sym] = @filters[key]
        end
        ApplicationRecord.sanitize_sql([ clauses.join(" "), binds ])
      end

      def quarters
        <<~SQL
          periods AS (
            SELECT DISTINCT period_of_report FROM evidence
          ), portfolio_coverage AS (
            SELECT p.period_of_report, (SELECT COUNT(*) FROM cohort) AS expected_fund_count,
              COUNT(x.institutional_filer_id) AS reporting_fund_count,
              COUNT(x.institutional_filer_id) FILTER (WHERE x.suspect) AS suspect_report_fund_count,
              COALESCE(i.excluded_rows, 0) AS excluded_holding_rows,
              COUNT(x.institutional_filer_id) = (SELECT COUNT(*) FROM cohort)
                AND COUNT(*) FILTER (WHERE x.suspect) = 0 AND COALESCE(i.excluded_rows, 0) = 0 AS complete
            FROM periods p LEFT JOIN contexts x ON x.period_of_report = p.period_of_report
            LEFT JOIN invalid i ON i.period_of_report = p.period_of_report
            GROUP BY p.period_of_report, i.excluded_rows
          ), position_groups AS (
            SELECT l.period_of_report, l.cusip, l.put_call, l.share_type, MIN(l.name_of_issuer) AS issuer_name,
              COUNT(*) AS row_count, COUNT(DISTINCT l.institutional_filer_id) AS observed_holder_count,
              SUM(l.shares) AS shares_reported,
              CASE WHEN COUNT(*) = COUNT(l.value_usd) THEN SUM(l.value_usd) END AS value_usd_reported,
              BOOL_OR(l.suspect OR l.report_suspect) AS suspect,
              COUNT(DISTINCT l.institutional_report_id) AS source_count,
              (ARRAY_AGG(l.institutional_report_id ORDER BY COALESCE(f.filed_at, r.filed_at) DESC, f.accession_no DESC, l.id DESC))[1] AS primary_report_id
            FROM matched l INNER JOIN institutional_reports r ON r.id = l.institutional_report_id
            INNER JOIN filings f ON f.id = r.filing_id
            GROUP BY l.period_of_report, l.cusip, l.put_call, l.share_type
          ), ranked_positions AS (
            SELECT g.*, ROW_NUMBER() OVER (PARTITION BY period_of_report ORDER BY cusip, put_call NULLS FIRST, share_type) AS position_rank
            FROM position_groups g
          ), positions AS (
            SELECT g.period_of_report, COUNT(*) AS position_count,
              COALESCE(jsonb_agg(jsonb_build_object('cusip', g.cusip, 'put_call', g.put_call,
                'share_type', g.share_type, 'issuer_name', g.issuer_name, 'row_count', g.row_count,
                'observed_holder_count', g.observed_holder_count, 'shares_reported', g.shares_reported::text,
                'value_usd_reported', g.value_usd_reported::text, 'suspect', g.suspect,
                'shares', CASE WHEN c.complete AND NOT g.suspect THEN g.shares_reported::text END,
                'value_usd', CASE WHEN c.complete AND NOT g.suspect THEN g.value_usd_reported::text END,
                'source_count', g.source_count, 'primary_report_id', g.primary_report_id)
                ORDER BY g.position_rank) FILTER (WHERE g.position_rank <= #{POSITION_LIMIT}), '[]'::jsonb) AS positions
            FROM ranked_positions g INNER JOIN portfolio_coverage c USING (period_of_report)
            GROUP BY g.period_of_report
          ), source_groups AS (
            SELECT period_of_report, COUNT(*) AS source_count,
              (ARRAY_AGG(id ORDER BY known_filed_at DESC, known_accession DESC))[1:#{SOURCE_LIMIT}] AS report_ids,
              (ARRAY_AGG(id ORDER BY known_filed_at DESC, known_accession DESC))[1] AS primary_report_id,
              COUNT(DISTINCT institutional_filer_id) FILTER (WHERE submission_type = '13F-NT') AS notice_fund_count
            FROM evidence GROUP BY period_of_report
          ), matched_counts AS (
            SELECT period_of_report, COUNT(*) AS holding_row_count, COUNT(DISTINCT institutional_filer_id) AS observed_holder_count,
              BOOL_OR(suspect OR report_suspect) AS suspect
            FROM matched GROUP BY period_of_report
          ), summary AS (
            SELECT c.*, c.expected_fund_count - c.reporting_fund_count AS missing_fund_count,
              COALESCE(m.observed_holder_count, 0) AS observed_holder_count,
              CASE WHEN c.complete THEN COALESCE(m.observed_holder_count, 0) END AS holder_count,
              COALESCE(m.holding_row_count, 0) AS holding_row_count,
              COALESCE(m.suspect, false) OR c.suspect_report_fund_count > 0 OR c.excluded_holding_rows > 0 AS suspect,
              COALESCE(p.positions, '[]'::jsonb) AS positions, COALESCE(p.position_count, 0) AS position_count,
              COALESCE(s.source_count, 0) AS source_count, COALESCE(s.notice_fund_count, 0) AS notice_fund_count,
              COALESCE(s.report_ids, ARRAY[]::bigint[]) AS report_ids, s.primary_report_id
            FROM portfolio_coverage c LEFT JOIN positions p USING (period_of_report)
            LEFT JOIN source_groups s USING (period_of_report) LEFT JOIN matched_counts m USING (period_of_report)
          )
        SQL
      end
    end
  end
end
