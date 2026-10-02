# frozen_string_literal: true

# Returns the signed-in user's followed profiles and their latest parsed filing
# activity. The three target types are combined in SQL so the page does not
# resolve each follow with a separate query.
class Watchlist
  def initialize(user:)
    @user = user
  end

  def entries(limit: 100)
    ApplicationRecord.connection.select_all(
      ApplicationRecord.sanitize_sql([ sql, { user_id: @user.id, limit: } ])
    ).to_a
  end

  private

  def sql
    <<~SQL
      WITH insider_activity AS (
        SELECT t.insider_cik AS target_key,
               (array_agg(t.insider_name ORDER BY f.filed_at DESC NULLS LAST))[1] AS label,
               MAX(f.filed_at) AS last_filed_at,
               COUNT(*) AS activity_count
        FROM insider_transactions t
        INNER JOIN filings f ON f.id = t.filing_id
        WHERE f.parse_status = 'parsed'
        GROUP BY t.insider_cik
      ), institution_activity AS (
        SELECT i.cik AS target_key,
               i.name AS label,
               MAX(r.filed_at) AS last_filed_at,
               COUNT(r.id) AS activity_count
        FROM institutional_filers i
        LEFT JOIN institutional_reports r
          ON r.institutional_filer_id = i.id
         AND r.status = 'parsed'
        GROUP BY i.id
      ), ticker_activity AS (
        SELECT COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker) AS target_key,
               (array_agg(f.issuer_name ORDER BY f.filed_at DESC NULLS LAST))[1] AS label,
               MAX(f.filed_at) AS last_filed_at,
               COUNT(*) AS activity_count
        FROM insider_transactions t
        INNER JOIN filings f ON f.id = t.filing_id
        WHERE f.parse_status = 'parsed'
          AND COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker) IS NOT NULL
        GROUP BY COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker)
      ), entries AS (
        SELECT follows.id AS follow_id,
               follows.target_type,
               follows.target_key,
               COALESCE(insider_activity.label, follows.target_key) AS label,
               insider_activity.last_filed_at,
               COALESCE(insider_activity.activity_count, 0) AS activity_count
        FROM follows
        LEFT JOIN insider_activity ON insider_activity.target_key = follows.target_key
        WHERE follows.user_id = :user_id
          AND follows.target_type = 'Insider'

        UNION ALL

        SELECT follows.id AS follow_id,
               follows.target_type,
               follows.target_key,
               COALESCE(institution_activity.label, follows.target_key) AS label,
               institution_activity.last_filed_at,
               COALESCE(institution_activity.activity_count, 0) AS activity_count
        FROM follows
        LEFT JOIN institution_activity ON institution_activity.target_key = follows.target_key
        WHERE follows.user_id = :user_id
          AND follows.target_type = 'InstitutionalFiler'

        UNION ALL

        SELECT follows.id AS follow_id,
               follows.target_type,
               follows.target_key,
               COALESCE(ticker_activity.label, follows.target_key) AS label,
               ticker_activity.last_filed_at,
               COALESCE(ticker_activity.activity_count, 0) AS activity_count
        FROM follows
        LEFT JOIN ticker_activity ON ticker_activity.target_key = follows.target_key
        WHERE follows.user_id = :user_id
          AND follows.target_type = 'Ticker'
      )
      SELECT *
      FROM entries
      ORDER BY last_filed_at DESC NULLS LAST, label, follow_id
      LIMIT :limit
    SQL
  end
end
