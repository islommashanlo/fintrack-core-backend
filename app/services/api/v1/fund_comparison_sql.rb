# frozen_string_literal: true

module Api
  module V1
    class FundComparisonSql
      VALID_KEY = InstitutionalHoldingKey::VALID_SQL

      def initialize(page:, funds:, reports:, period:)
        @page, @funds, @reports, @period = page, funds, reports, period
        @prior = period && (period << 3).end_of_quarter
      end

      def fund_states
        <<~SQL
          WITH #{ctes}
          SELECT *, BOOL_OR(current_report_present) OVER () AS any_current_report,
            BOOL_AND(current_available) OVER () AS comparison_complete,
            BOOL_AND(prior_available) OVER () AS comparison_prior_complete
          FROM fund_state ORDER BY cik
        SQL
      end

      def overlaps
        <<~SQL
          WITH #{ctes}
          SELECT a.cik AS left_cik, b.cik AS right_cik,
            a.current_available AND b.current_available AS complete,
            CASE WHEN a.current_available AND b.current_available THEN counts.shared END AS shared_position_count,
            CASE WHEN a.current_available AND b.current_available THEN counts.union_count END AS union_position_count,
            CASE WHEN a.current_available AND b.current_available THEN
              100.0 * counts.shared / NULLIF(counts.union_count, 0) END AS overlap_percent,
            CASE WHEN a.current_available AND b.current_available AND a.prior_available AND b.prior_available
              AND counts.moves_known THEN counts.differing END AS differing_move_count,
            #{primary_report('r.institutional_filer_id IN (a.id, b.id)')} AS primary_report_id
          FROM fund_state a INNER JOIN fund_state b ON a.cik < b.cik
          CROSS JOIN LATERAL (
            SELECT COUNT(*) FILTER (WHERE l.current_present AND r.current_present) AS shared,
              COUNT(*) FILTER (WHERE l.current_present OR r.current_present) AS union_count,
              COALESCE(BOOL_AND(l.change_type <> 'unknown' AND r.change_type <> 'unknown'), true) AS moves_known,
              COUNT(*) FILTER (WHERE l.change_type <> r.change_type) AS differing
            FROM matrix l INNER JOIN matrix r ON r.cusip = l.cusip AND r.put_call_key = l.put_call_key AND r.share_type = l.share_type
            WHERE l.fund_id = a.id AND r.fund_id = b.id
          ) counts
          ORDER BY a.cik, b.cik
        SQL
      end

      def positions(filters)
        conditions, binds = [], {}
        conditions << "holder_count >= 2" if filters["scope"] == "shared"
        conditions << "differing_moves IS TRUE" if filters["scope"] == "differing_moves"
        %w[cusip put_call share_type].each do |key|
          next unless filters[key]
          conditions << "#{key} = :#{key}"
          binds[key.to_sym] = filters[key]
        end
        ApplicationRecord.sanitize_sql([ <<~SQL, binds ])
          WITH #{ctes}, positions AS (
            SELECT cusip, NULLIF(put_call_key, '') AS put_call, share_type,
              MIN(issuer_name) AS issuer_name, COUNT(*) FILTER (WHERE current_present) AS holder_count,
              CASE WHEN BOOL_AND(current_available) THEN BOOL_AND(current_present) END AS shared_by_all,
              CASE WHEN BOOL_AND(change_type <> 'unknown') THEN COUNT(DISTINCT change_type) > 1 END AS differing_moves,
              jsonb_agg(jsonb_build_object('cik', cik, 'present', current_present,
                'shares', shares::text, 'value_usd', value_usd::text, 'prior_shares', prior_shares::text,
                'prior_value_usd', prior_value_usd::text, 'shares_delta', shares_delta::text,
                'value_usd_delta', value_usd_delta::text, 'change_type', change_type,
                'weight_percent', weight_percent::text, 'prior_weight_percent', prior_weight_percent::text,
                'rank', position_rank, 'prior_rank', prior_position_rank,
                'suspect', suspect, 'prior_suspect', prior_suspect, 'row_count', row_count)
                ORDER BY cik) AS funds,
              jsonb_build_array(cusip, put_call_key, share_type)::text AS event_key,
              #{primary_report('TRUE')} AS primary_report_id
            FROM matrix GROUP BY cusip, put_call_key, share_type
          ) SELECT * FROM positions #{conditions.empty? ? '' : "WHERE #{conditions.join(' AND ')}"}
        SQL
      end

      private

      def quote(value) = ApplicationRecord.connection.quote(value)

      def primary_report(condition)
        <<~SQL.squish
          (SELECT r.id FROM effective r INNER JOIN filings f ON f.id = r.filing_id
            WHERE #{condition} ORDER BY COALESCE(f.filed_at, r.filed_at) DESC, f.accession_no DESC LIMIT 1)
        SQL
      end

      def ctes
        ids = @funds.map(&:id)
        periods = [ @period, @prior ].compact
        visible = @reports.visible_reports.where(institutional_filer_id: ids, period_of_report: periods)
        effective = @reports.effective_reports.where(institutional_filer_id: ids, period_of_report: periods)
        diff_scope = InstitutionalReportScope.new(as_of: @page.as_of, max_report_id: @page.bound("reports"),
          max_filing_id: @page.bound("filings"), report_ids: effective.select(:id))
        changes = InstitutionalPositionDiffQuery.new(period_of_report: @period, report_scope: diff_scope,
          max_holding_id: @page.bound("holdings")).to_sql
        <<~SQL
          visible AS (#{visible.to_sql}), value_checks AS (#{InstitutionalReportChecks.sql(max_holding_id: @page.bound('holdings'))}),
          effective AS (#{effective.to_sql}), contexts AS (
            SELECT institutional_filer_id, period_of_report, ARRAY_AGG(id ORDER BY id) AS report_ids, BOOL_OR(suspect) AS suspect
            FROM effective GROUP BY institutional_filer_id, period_of_report
          ), lines AS (
            SELECT r.institutional_filer_id, r.period_of_report, h.cusip, COALESCE(h.put_call, '') AS put_call_key, h.share_type,
              MIN(h.name_of_issuer) AS issuer_name, COUNT(*) AS row_count,
              CASE WHEN COUNT(*) = COUNT(h.shares) THEN SUM(h.shares) END AS shares,
              CASE WHEN COUNT(*) = COUNT(h.value_usd) THEN SUM(h.value_usd) END AS value_usd,
              BOOL_OR(h.suspect) AS suspect
            FROM effective r INNER JOIN institutional_holdings h ON h.institutional_report_id = r.id
            WHERE h.id <= #{@page.bound('holdings')} AND #{VALID_KEY}
            GROUP BY r.institutional_filer_id, r.period_of_report, h.cusip, COALESCE(h.put_call, ''), h.share_type
          ), ranked_lines AS (
            SELECT lines.*, RANK() OVER (
              PARTITION BY institutional_filer_id, period_of_report ORDER BY value_usd DESC NULLS LAST
            ) AS position_rank FROM lines
          ), invalid AS (
            SELECT r.institutional_filer_id, r.period_of_report, COUNT(*) AS rows
            FROM effective r INNER JOIN institutional_holdings h ON h.institutional_report_id = r.id
            WHERE h.id <= #{@page.bound('holdings')} AND (#{VALID_KEY}) IS NOT TRUE
            GROUP BY r.institutional_filer_id, r.period_of_report
          ), value_contexts AS (
            SELECT r.institutional_filer_id, r.period_of_report,
              BOOL_AND(COALESCE(v.structure_complete AND v.values_complete, false)) AS complete,
              CASE WHEN BOOL_AND(COALESCE(v.structure_complete AND v.values_complete, false)) THEN COALESCE((
                SELECT SUM(l.value_usd) FROM lines l WHERE l.institutional_filer_id = r.institutional_filer_id
                  AND l.period_of_report = r.period_of_report
              ), 0.0) END AS total_value_usd
            FROM effective r INNER JOIN value_checks v ON v.id = r.id
            GROUP BY r.institutional_filer_id, r.period_of_report
          ), fund_state AS (
            SELECT f.id, f.cik, f.name, c.report_ids AS current_report_ids, p.report_ids AS prior_report_ids,
              c.report_ids IS NOT NULL AS current_report_present, p.report_ids IS NOT NULL AS prior_report_present,
              c.report_ids IS NOT NULL AND NOT c.suspect AND COALESCE(ic.rows, 0) = 0 AS current_available,
              p.report_ids IS NOT NULL AND NOT p.suspect AND COALESCE(ip.rows, 0) = 0 AS prior_available,
              COALESCE(c.suspect, false) AS current_report_suspect, COALESCE(p.suspect, false) AS prior_report_suspect,
              COALESCE(ic.rows, 0) AS excluded_current_rows, COALESCE(ip.rows, 0) AS excluded_prior_rows,
              COALESCE(vc.complete, false) AS current_value_complete, COALESCE(vp.complete, false) AS prior_value_complete,
              vc.total_value_usd AS current_portfolio_value_usd, vp.total_value_usd AS prior_portfolio_value_usd,
              CASE WHEN c.report_ids IS NOT NULL AND NOT c.suspect AND COALESCE(ic.rows, 0) = 0 THEN
                (SELECT COUNT(*) FROM lines l WHERE l.institutional_filer_id = f.id AND l.period_of_report = #{quote(@period)}) END AS position_count,
              #{primary_report('r.institutional_filer_id = f.id')} AS primary_report_id
            FROM institutional_filers f
            LEFT JOIN contexts c ON c.institutional_filer_id = f.id AND c.period_of_report = #{quote(@period)}
            LEFT JOIN contexts p ON p.institutional_filer_id = f.id AND p.period_of_report = #{quote(@prior)}
            LEFT JOIN value_contexts vc ON vc.institutional_filer_id = f.id AND vc.period_of_report = #{quote(@period)}
            LEFT JOIN value_contexts vp ON vp.institutional_filer_id = f.id AND vp.period_of_report = #{quote(@prior)}
            LEFT JOIN invalid ic ON ic.institutional_filer_id = f.id AND ic.period_of_report = #{quote(@period)}
            LEFT JOIN invalid ip ON ip.institutional_filer_id = f.id AND ip.period_of_report = #{quote(@prior)}
            WHERE f.id IN (#{ids.join(',')})
          ), keys AS (
            SELECT DISTINCT cusip, put_call_key, share_type FROM lines
          ), changes AS (#{changes}), raw_matrix AS (
            SELECT s.id AS fund_id, s.cik, s.current_available, s.prior_available,
              k.*, COALESCE(c.issuer_name, p.issuer_name) AS issuer_name,
              CASE WHEN c.cusip IS NOT NULL THEN true WHEN s.current_available THEN false END AS current_present,
              c.shares, c.value_usd, p.shares AS prior_shares, p.value_usd AS prior_value_usd,
              CASE WHEN s.current_value_complete THEN c.position_rank END AS position_rank,
              CASE WHEN s.prior_value_complete THEN p.position_rank END AS prior_position_rank,
              CASE WHEN s.current_value_complete AND s.current_portfolio_value_usd > 0 AND c.cusip IS NOT NULL
                THEN c.value_usd * 100 / s.current_portfolio_value_usd END AS weight_percent,
              CASE WHEN s.prior_value_complete AND s.prior_portfolio_value_usd > 0 AND p.cusip IS NOT NULL
                THEN p.value_usd * 100 / s.prior_portfolio_value_usd END AS prior_weight_percent,
              COALESCE(c.suspect, false) OR s.current_report_suspect AS suspect,
              COALESCE(p.suspect, false) OR s.prior_report_suspect AS prior_suspect,
              COALESCE(c.row_count, 0) AS row_count,
              CASE WHEN NOT s.current_available OR NOT s.prior_available OR COALESCE(c.suspect, false) OR COALESCE(p.suspect, false)
                  OR (c.cusip IS NOT NULL AND c.shares IS NULL) OR (p.cusip IS NOT NULL AND p.shares IS NULL) THEN 'unknown'
                WHEN c.cusip IS NULL AND p.cusip IS NULL THEN 'not_reported'
                WHEN d.change_type = 'new' THEN 'new' WHEN d.change_type = 'add' THEN 'added'
                WHEN d.change_type = 'trim' THEN 'reduced' WHEN d.change_type = 'exit' THEN 'exited' ELSE 'unchanged' END AS change_type
            FROM fund_state s CROSS JOIN keys k
            LEFT JOIN ranked_lines c ON c.institutional_filer_id = s.id AND c.period_of_report = #{quote(@period)}
              AND c.cusip = k.cusip AND c.put_call_key = k.put_call_key AND c.share_type = k.share_type
            LEFT JOIN ranked_lines p ON p.institutional_filer_id = s.id AND p.period_of_report = #{quote(@prior)}
              AND p.cusip = k.cusip AND p.put_call_key = k.put_call_key AND p.share_type = k.share_type
            LEFT JOIN changes d ON d.institutional_filer_id = s.id AND d.cusip = k.cusip
              AND COALESCE(d.put_call, '') = k.put_call_key AND d.share_type = k.share_type
          ), matrix AS (
            SELECT raw_matrix.*,
              CASE WHEN change_type <> 'unknown' THEN COALESCE(shares, 0) - COALESCE(prior_shares, 0) END AS shares_delta,
              CASE WHEN change_type <> 'unknown' AND (current_present IS FALSE OR value_usd IS NOT NULL)
                AND (prior_shares IS NULL OR prior_value_usd IS NOT NULL) THEN COALESCE(value_usd, 0) - COALESCE(prior_value_usd, 0) END AS value_usd_delta
            FROM raw_matrix
          )
        SQL
      end
    end
  end
end
