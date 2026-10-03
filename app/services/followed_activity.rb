# frozen_string_literal: true

# Reads recent parsed activity for the current user's follows in one SQL feed.
# Form 4 activity is resolved by insider CIK or issuer ticker; institution
# activity is represented by its parsed 13F report filings.
class FollowedActivity
  FORM4_ACTIVITY = <<~SQL
    SELECT t.insider_cik,
           t.insider_name,
           COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker) AS issuer_ticker,
           f.issuer_name,
           f.filed_at,
           f.cik AS filing_cik,
           f.accession_no,
           t.transaction_code,
           t.shares,
           t.price,
           t.price_suspect,
           f.aff10b5_one AS plan_disclosed,
           f.footnotes AS filing_footnotes,
           t.footnote_ids AS transaction_footnote_ids,
           CASE WHEN t.price IS NOT NULL AND NOT t.price_suspect THEN t.shares * t.price END AS value
    FROM insider_transactions t
    INNER JOIN filings f ON f.id = t.filing_id
    WHERE f.parse_status = 'parsed'
      AND t.security_table = 'non_derivative'
      AND t.owner_seq = 1
      AND t.transaction_code IN ('P', 'S')
      AND f.filed_at > :since
      AND f.filed_at <= :as_of
      AND NOT EXISTS (
        SELECT 1
        FROM filings later
        WHERE later.amends_accession_no = COALESCE(f.amends_accession_no, f.accession_no)
          AND later.filed_at > f.filed_at
          AND later.filed_at <= :as_of
      )
  SQL

  def initialize(user:, as_of: Time.current)
    @user = user
    @as_of = as_of
  end

  def recent(days: 30, limit: 20)
    binds = { user_id: @user.id, since: @as_of - days.days, as_of: @as_of, limit: }
    rows = ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([ sql, binds ])).to_a

    rows.map do |row|
      next row unless row["activity_source"] == "Form 4"

      Form4PlanClassifier.annotate(row)
    end
  end

  private

  def sql
    <<~SQL
      WITH form4_activity AS (
        #{FORM4_ACTIVITY}
      ), feed AS (
        SELECT follows.id AS follow_id,
               follows.target_type,
               follows.target_key,
               COALESCE(form4_activity.insider_name, form4_activity.issuer_name, follows.target_key) AS label,
               'Form 4' AS activity_source,
               form4_activity.filed_at,
               form4_activity.filing_cik,
               form4_activity.accession_no,
               form4_activity.transaction_code AS activity_kind,
               form4_activity.issuer_ticker,
               form4_activity.issuer_name,
               form4_activity.shares,
               form4_activity.price,
               form4_activity.price_suspect,
               form4_activity.plan_disclosed,
               form4_activity.filing_footnotes,
               form4_activity.transaction_footnote_ids,
               form4_activity.value,
               NULL::date AS period_of_report,
               NULL::text AS report_type
        FROM follows
        INNER JOIN form4_activity
          ON (follows.target_type = 'Insider' AND form4_activity.insider_cik = follows.target_key)
          OR (follows.target_type = 'Ticker' AND form4_activity.issuer_ticker = follows.target_key)
        WHERE follows.user_id = :user_id
          AND follows.target_type IN ('Insider', 'Ticker')

        UNION ALL

        SELECT follows.id AS follow_id,
               follows.target_type,
               follows.target_key,
               institutions.name AS label,
               '13F' AS activity_source,
               COALESCE(reports.filed_at, filings.filed_at) AS filed_at,
               filings.cik AS filing_cik,
               filings.accession_no,
               reports.submission_type AS activity_kind,
               NULL::text AS issuer_ticker,
               NULL::text AS issuer_name,
               NULL::numeric AS shares,
               NULL::numeric AS price,
               NULL::boolean AS price_suspect,
               NULL::boolean AS plan_disclosed,
               NULL::jsonb AS filing_footnotes,
               NULL::text[] AS transaction_footnote_ids,
               NULL::numeric AS value,
               reports.period_of_report,
               reports.report_type
        FROM follows
        INNER JOIN institutional_filers institutions ON institutions.cik = follows.target_key
        INNER JOIN institutional_reports reports
          ON reports.institutional_filer_id = institutions.id
         AND reports.status = 'parsed'
        INNER JOIN filings ON filings.id = reports.filing_id
        WHERE follows.user_id = :user_id
          AND follows.target_type = 'InstitutionalFiler'
          AND COALESCE(reports.filed_at, filings.filed_at) > :since
          AND COALESCE(reports.filed_at, filings.filed_at) <= :as_of
      )
      SELECT *
      FROM feed
      ORDER BY filed_at DESC NULLS LAST, accession_no, follow_id
      LIMIT :limit
    SQL
  end
end
