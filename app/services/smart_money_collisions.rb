# frozen_string_literal: true

# Finds tickers where Form 4 purchases and 13F additions were filed within the
# same point-in-time window. The match uses existing CUSIP mappings and keeps
# all set logic in SQL.
class SmartMoneyCollisions
  def initialize(as_of: Time.current)
    @as_of = as_of
  end

  def matches(days: 90, window_days: 45, limit: 8)
    ApplicationRecord.connection.select_all(
      ApplicationRecord.sanitize_sql([ sql, { as_of: @as_of, since: @as_of - days.days, window_days:, limit: } ])
    ).to_a
  end

  private

  def sql
    <<~SQL
      WITH mapped_securities AS (
        SELECT DISTINCT ON (m.cusip)
               m.cusip, s.ticker
        FROM cusip_security_mappings m
        INNER JOIN securities s ON s.id = m.security_id
        WHERE m.status = 'mapped'
          AND s.ticker IS NOT NULL
          AND s.ticker <> ''
        ORDER BY m.cusip, m.last_checked_at DESC, m.result_seq
      ), insider_purchases AS (
        SELECT f.id AS filing_id,
               f.issuer_name,
               COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker) AS ticker,
               t.insider_cik,
               f.filed_at
        FROM insider_transactions t
        INNER JOIN filings f ON f.id = t.filing_id
        WHERE f.parse_status = 'parsed'
          AND t.security_table = 'non_derivative'
          AND t.owner_seq = 1
          AND t.transaction_code = 'P'
          AND f.filed_at > :since
          AND f.filed_at <= :as_of
          AND COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker) IS NOT NULL
          AND COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker) <> ''
          AND NOT EXISTS (
            SELECT 1
            FROM filings later
            WHERE later.amends_accession_no = COALESCE(f.amends_accession_no, f.accession_no)
              AND later.filed_at > f.filed_at
              AND later.filed_at <= :as_of
          )
      ), institutional_additions AS (
        SELECT r.id AS report_id,
               d.institutional_filer_id,
               r.filed_at,
               ms.ticker
        FROM position_diffs d
        INNER JOIN institutional_reports r ON r.id = d.institutional_report_id
        INNER JOIN mapped_securities ms ON ms.cusip = d.cusip
        WHERE r.status = 'parsed'
          AND d.change_type IN ('new', 'add')
          AND r.filed_at > :since
          AND r.filed_at <= :as_of
      ), matched_pairs AS (
        SELECT DISTINCT ip.filing_id,
                        ip.insider_cik,
                        ia.report_id,
                        ia.institutional_filer_id,
                        ip.issuer_name,
                        ip.ticker,
                        ip.filed_at AS insider_filed_at,
                        ia.filed_at AS institution_filed_at
        FROM insider_purchases ip
        INNER JOIN institutional_additions ia
          ON ia.ticker ILIKE ip.ticker
         AND ip.filed_at BETWEEN ia.filed_at - (:window_days * INTERVAL '1 day')
                             AND ia.filed_at + (:window_days * INTERVAL '1 day')
      )
      SELECT ticker,
             MAX(issuer_name) AS issuer_name,
             COUNT(DISTINCT insider_cik) AS insiders,
             COUNT(DISTINCT institutional_filer_id) AS institutions,
             COUNT(DISTINCT filing_id) AS insider_filings,
             COUNT(DISTINCT report_id) AS institutional_reports,
             MAX(insider_filed_at) AS latest_insider_filed_at,
             MAX(institution_filed_at) AS latest_institution_filed_at
      FROM matched_pairs
      GROUP BY ticker
      ORDER BY COUNT(DISTINCT insider_cik) DESC,
               COUNT(DISTINCT institutional_filer_id) DESC,
               GREATEST(MAX(insider_filed_at), MAX(institution_filed_at)) DESC,
               ticker
      LIMIT :limit
    SQL
  end
end
