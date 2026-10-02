# frozen_string_literal: true

# Produces quarter-to-quarter institutional position changes with SQL set logic.
# Holdings are first aggregated by CUSIP, put/call and share type so repeated
# information-table lines for one security do not become false diffs.
class InstitutionalPositionDiffQuery
  def initialize(institutional_filer_id: nil, period_of_report: nil)
    @institutional_filer_id = institutional_filer_id
    @period_of_report = period_of_report
  end

  def call
    ApplicationRecord.connection.select_all(
      ApplicationRecord.sanitize_sql([ sql, binds ])
    ).to_a
  end

  private

  def sql
    <<~SQL
      WITH base_reports AS (
        SELECT DISTINCT ON (r.institutional_filer_id, r.period_of_report)
               r.id,
               r.institutional_filer_id,
               r.period_of_report,
               COALESCE(r.filed_at, TIMESTAMP 'epoch') AS filed_at
        FROM institutional_reports r
        WHERE r.status = 'parsed'
          AND (r.amendment_type IS NULL OR r.amendment_type = 'RESTATEMENT')
          #{filer_filter}
        ORDER BY r.institutional_filer_id, r.period_of_report,
                 r.filed_at DESC NULLS LAST, r.id DESC
      ), quarter_pairs AS (
        SELECT b.*,
               LAG(b.period_of_report) OVER (
                 PARTITION BY b.institutional_filer_id ORDER BY b.period_of_report
               ) AS prior_period_of_report
        FROM base_reports b
      ), effective_reports AS (
        SELECT b.institutional_filer_id, b.period_of_report, b.id AS report_id
        FROM base_reports b
        UNION ALL
        SELECT b.institutional_filer_id, b.period_of_report, amendment.id AS report_id
        FROM base_reports b
        INNER JOIN institutional_reports amendment
          ON amendment.institutional_filer_id = b.institutional_filer_id
         AND amendment.period_of_report = b.period_of_report
         AND amendment.status = 'parsed'
         AND amendment.amendment_type = 'NEW HOLDINGS'
         AND COALESCE(amendment.filed_at, TIMESTAMP 'epoch') > b.filed_at
      ), effective_lines AS (
        SELECT er.institutional_filer_id,
               er.period_of_report,
               h.cusip,
               COALESCE(h.put_call, '') AS put_call_key,
               h.share_type,
               SUM(h.shares) AS shares,
               SUM(h.value_usd) AS value_usd,
               BOOL_OR(h.suspect) AS suspect,
               MAX(er.report_id) AS report_id,
               MIN(h.name_of_issuer) AS name_of_issuer,
               MIN(h.title_of_class) AS title_of_class
        FROM effective_reports er
        INNER JOIN institutional_holdings h ON h.institutional_report_id = er.report_id
        WHERE h.cusip ~ '^[0-9A-Z]{9}$'
        GROUP BY er.institutional_filer_id, er.period_of_report, h.cusip,
                 COALESCE(h.put_call, ''), h.share_type
      ), security_keys AS (
        SELECT qp.institutional_filer_id, qp.period_of_report, qp.prior_period_of_report,
               current_line.cusip, current_line.put_call_key, current_line.share_type
        FROM quarter_pairs qp
        INNER JOIN effective_lines current_line
          ON current_line.institutional_filer_id = qp.institutional_filer_id
         AND current_line.period_of_report = qp.period_of_report
        UNION
        SELECT qp.institutional_filer_id, qp.period_of_report, qp.prior_period_of_report,
               prior_line.cusip, prior_line.put_call_key, prior_line.share_type
        FROM quarter_pairs qp
        INNER JOIN effective_lines prior_line
          ON prior_line.institutional_filer_id = qp.institutional_filer_id
         AND prior_line.period_of_report = qp.prior_period_of_report
      ), diffs AS (
        SELECT k.institutional_filer_id,
               k.period_of_report,
               k.prior_period_of_report,
               k.cusip,
               NULLIF(k.put_call_key, '') AS put_call,
               k.share_type,
               CASE
                 WHEN prior_line.cusip IS NULL THEN 'new'
                 WHEN current_line.cusip IS NULL THEN 'exit'
                 WHEN current_line.shares > prior_line.shares THEN 'add'
                 ELSE 'trim'
               END AS change_type,
               prior_line.shares AS shares_before,
               current_line.shares AS shares_after,
               COALESCE(current_line.shares, 0) - COALESCE(prior_line.shares, 0) AS shares_delta,
               prior_line.value_usd AS value_usd_before,
               current_line.value_usd AS value_usd_after,
               CASE
                 WHEN current_line.cusip IS NULL THEN -prior_line.value_usd
                 WHEN prior_line.cusip IS NULL THEN current_line.value_usd
                 WHEN current_line.value_usd IS NULL OR prior_line.value_usd IS NULL THEN NULL
                 ELSE current_line.value_usd - prior_line.value_usd
               END AS value_usd_delta,
               COALESCE(current_line.name_of_issuer, prior_line.name_of_issuer) AS name_of_issuer,
               COALESCE(current_line.title_of_class, prior_line.title_of_class) AS title_of_class,
               COALESCE(current_line.suspect, false) AS current_suspect,
               COALESCE(prior_line.suspect, false) AS prior_suspect,
               current_line.report_id AS current_report_id,
               prior_line.report_id AS prior_report_id
        FROM security_keys k
        LEFT JOIN effective_lines current_line
          ON current_line.institutional_filer_id = k.institutional_filer_id
         AND current_line.period_of_report = k.period_of_report
         AND current_line.cusip = k.cusip
         AND current_line.put_call_key = k.put_call_key
         AND current_line.share_type = k.share_type
        LEFT JOIN effective_lines prior_line
          ON prior_line.institutional_filer_id = k.institutional_filer_id
         AND prior_line.period_of_report = k.prior_period_of_report
         AND prior_line.cusip = k.cusip
         AND prior_line.put_call_key = k.put_call_key
         AND prior_line.share_type = k.share_type
        WHERE prior_line.cusip IS NULL
           OR current_line.cusip IS NULL
           OR current_line.shares <> prior_line.shares
      )
      SELECT *
      FROM diffs
      WHERE 1 = 1
        #{period_filter}
      ORDER BY institutional_filer_id, period_of_report, cusip, put_call NULLS FIRST, share_type
    SQL
  end

  def filer_filter
    @institutional_filer_id ? "AND r.institutional_filer_id = :institutional_filer_id" : ""
  end

  def period_filter
    @period_of_report ? "AND period_of_report = :period_of_report" : ""
  end

  def binds
    {
      institutional_filer_id: @institutional_filer_id,
      period_of_report: @period_of_report
    }
  end
end
