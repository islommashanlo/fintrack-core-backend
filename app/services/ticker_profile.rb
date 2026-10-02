# frozen_string_literal: true

# Read-only ticker queries. Insider activity is available from Form 4 records;
# institutional rows are shown only when an existing CUSIP mapping identifies
# the security, so the page never guesses a ticker from an issuer name.
class TickerProfile
  VALUE = "t.shares * t.price"
  USABLE_PRICE = "t.price IS NOT NULL AND NOT t.price_suspect"
  TRANSACTIONS = <<~SQL
    FROM insider_transactions t
    INNER JOIN filings f ON f.id = t.filing_id
    WHERE f.parse_status = 'parsed'
      AND t.security_table = 'non_derivative'
      AND t.owner_seq = 1
      AND t.transaction_code IN ('P', 'S')
      AND COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker) ILIKE :ticker_pattern
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

  def initialize(ticker:, as_of: Time.current)
    @ticker = ticker.to_s.strip
    @as_of = as_of
  end

  def issuer
    select(<<~SQL, since: Time.at(0), limit: 1).first
      SELECT f.issuer_cik,
             f.issuer_name,
             COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker) AS issuer_ticker
      #{TRANSACTIONS}
      ORDER BY f.filed_at DESC, f.accession_no
      LIMIT :limit
    SQL
  end

  def summary(days: 90)
    select(<<~SQL, since: @as_of - days.days, limit: 1).first || {}
      SELECT COUNT(*) FILTER (WHERE t.transaction_code = 'P') AS purchase_count,
             COUNT(*) FILTER (WHERE t.transaction_code = 'S') AS sale_count,
             COUNT(DISTINCT t.insider_cik) AS insider_count,
             SUM(#{VALUE}) FILTER (WHERE t.transaction_code = 'P' AND #{USABLE_PRICE}) AS purchase_value,
             COUNT(*) FILTER (WHERE t.transaction_code = 'P' AND NOT (#{USABLE_PRICE})) AS purchases_without_usable_price,
             MAX(f.filed_at) AS last_filed_at
      #{TRANSACTIONS}
    SQL
  end

  def transactions(days: 365, limit: 40)
    select(<<~SQL, since: @as_of - days.days, limit:)
      SELECT f.filed_at, f.accession_no, f.issuer_cik, f.issuer_name,
             COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker) AS issuer_ticker,
             t.insider_cik, t.insider_name, t.transaction_date, t.transaction_code,
             t.shares, t.price, t.price_suspect, t.acquired_disposed,
             CASE WHEN f.aff10b5_one THEN '10b5-1 plan disclosed' END AS plan_status,
             CASE WHEN #{USABLE_PRICE} THEN #{VALUE} END AS value
      #{TRANSACTIONS}
      ORDER BY f.filed_at DESC, f.accession_no, t.txn_seq
      LIMIT :limit
    SQL
  end

  def institutional_holdings(limit: 24)
    select(<<~SQL, since: @as_of - 730.days, limit:)
      WITH mapped_securities AS (
        SELECT DISTINCT ON (m.cusip)
               m.cusip, s.ticker, s.name AS security_name
        FROM cusip_security_mappings m
        INNER JOIN securities s ON s.id = m.security_id
        WHERE m.status = 'mapped'
          AND s.ticker ILIKE :ticker_pattern
        ORDER BY m.cusip, m.last_checked_at DESC, m.result_seq
      ), latest_periods AS (
        SELECT DISTINCT ON (r.institutional_filer_id)
               r.institutional_filer_id, r.period_of_report
        FROM institutional_reports r
        WHERE r.status = 'parsed'
          AND r.filed_at <= :as_of
        ORDER BY r.institutional_filer_id, r.period_of_report DESC,
                 r.filed_at DESC NULLS LAST, r.id DESC
      ), latest_bases AS (
        SELECT DISTINCT ON (r.institutional_filer_id, r.period_of_report)
               r.id, r.institutional_filer_id, r.period_of_report,
               COALESCE(r.filed_at, TIMESTAMP 'epoch') AS filed_at
        FROM institutional_reports r
        INNER JOIN latest_periods lp
          ON lp.institutional_filer_id = r.institutional_filer_id
         AND lp.period_of_report = r.period_of_report
        WHERE r.status = 'parsed'
          AND (r.amendment_type IS NULL OR r.amendment_type = 'RESTATEMENT')
        ORDER BY r.institutional_filer_id, r.period_of_report,
                 r.filed_at DESC NULLS LAST, r.id DESC
      ), effective_reports AS (
        SELECT id, institutional_filer_id, period_of_report, filed_at
        FROM latest_bases
        UNION ALL
        SELECT r.id, r.institutional_filer_id, r.period_of_report,
               COALESCE(r.filed_at, TIMESTAMP 'epoch') AS filed_at
        FROM institutional_reports r
        INNER JOIN latest_bases b
          ON b.institutional_filer_id = r.institutional_filer_id
         AND b.period_of_report = r.period_of_report
        WHERE r.status = 'parsed'
          AND r.amendment_type = 'NEW HOLDINGS'
          AND COALESCE(r.filed_at, TIMESTAMP 'epoch') > b.filed_at
      )
      SELECT i.name AS institution_name,
             i.cik AS institution_cik,
             er.period_of_report,
             ms.cusip,
             ms.security_name,
             SUM(h.shares) AS shares,
             SUM(h.value_usd) AS value_usd,
             BOOL_OR(h.suspect) AS suspect
      FROM effective_reports er
      INNER JOIN institutional_filers i ON i.id = er.institutional_filer_id
      INNER JOIN institutional_holdings h ON h.institutional_report_id = er.id
      INNER JOIN mapped_securities ms ON ms.cusip = h.cusip
      GROUP BY i.id, i.name, i.cik, er.period_of_report, ms.cusip, ms.security_name
      ORDER BY value_usd DESC NULLS LAST, i.name
      LIMIT :limit
    SQL
  end

  def institutional_changes(limit: 24)
    select(<<~SQL, since: Time.at(0), limit:)
      WITH mapped_securities AS (
        SELECT DISTINCT ON (m.cusip)
               m.cusip, s.ticker, s.name AS security_name
        FROM cusip_security_mappings m
        INNER JOIN securities s ON s.id = m.security_id
        WHERE m.status = 'mapped'
          AND s.ticker ILIKE :ticker_pattern
        ORDER BY m.cusip, m.last_checked_at DESC, m.result_seq
      ), latest_periods AS (
        SELECT DISTINCT ON (r.institutional_filer_id)
               r.institutional_filer_id, r.period_of_report
        FROM institutional_reports r
        WHERE r.status = 'parsed'
          AND (r.filed_at IS NULL OR r.filed_at <= :as_of)
        ORDER BY r.institutional_filer_id, r.period_of_report DESC,
                 r.filed_at DESC NULLS LAST, r.id DESC
      )
      SELECT i.name AS institution_name,
             i.cik AS institution_cik,
             d.period_of_report,
             ms.cusip,
             ms.security_name,
             d.change_type,
             d.shares_delta,
             d.value_usd_delta,
             (d.current_suspect OR d.prior_suspect) AS suspect
      FROM position_diffs d
      INNER JOIN latest_periods lp
        ON lp.institutional_filer_id = d.institutional_filer_id
       AND lp.period_of_report = d.period_of_report
      INNER JOIN institutional_filers i ON i.id = d.institutional_filer_id
      INNER JOIN mapped_securities ms ON ms.cusip = d.cusip
      ORDER BY ABS(d.value_usd_delta) DESC NULLS LAST, i.name, d.cusip
      LIMIT :limit
    SQL
  end

  def institutional_history(periods: 4, limit: 48)
    select(<<~SQL, since: Time.at(0), periods:, limit:)
      WITH mapped_securities AS (
        SELECT DISTINCT ON (m.cusip)
               m.cusip, s.ticker, s.name AS security_name
        FROM cusip_security_mappings m
        INNER JOIN securities s ON s.id = m.security_id
        WHERE m.status = 'mapped'
          AND s.ticker ILIKE :ticker_pattern
        ORDER BY m.cusip, m.last_checked_at DESC, m.result_seq
      ), report_periods AS (
        SELECT DISTINCT r.institutional_filer_id, r.period_of_report
        FROM institutional_reports r
        WHERE r.status = 'parsed'
          AND (r.filed_at IS NULL OR r.filed_at <= :as_of)
      ), selected_periods AS (
        SELECT institutional_filer_id, period_of_report,
               ROW_NUMBER() OVER (
                 PARTITION BY institutional_filer_id
                 ORDER BY period_of_report DESC
               ) AS period_rank
        FROM report_periods
      ), latest_bases AS (
        SELECT DISTINCT ON (r.institutional_filer_id, r.period_of_report)
               r.id, r.institutional_filer_id, r.period_of_report,
               COALESCE(r.filed_at, TIMESTAMP 'epoch') AS filed_at
        FROM institutional_reports r
        INNER JOIN selected_periods sp
          ON sp.institutional_filer_id = r.institutional_filer_id
         AND sp.period_of_report = r.period_of_report
        WHERE sp.period_rank <= :periods
          AND r.status = 'parsed'
          AND (r.filed_at IS NULL OR r.filed_at <= :as_of)
          AND (r.amendment_type IS NULL OR r.amendment_type = 'RESTATEMENT')
        ORDER BY r.institutional_filer_id, r.period_of_report,
                 r.filed_at DESC NULLS LAST, r.id DESC
      ), effective_reports AS (
        SELECT id, institutional_filer_id, period_of_report, filed_at
        FROM latest_bases
        UNION ALL
        SELECT r.id, r.institutional_filer_id, r.period_of_report,
               COALESCE(r.filed_at, TIMESTAMP 'epoch') AS filed_at
        FROM institutional_reports r
        INNER JOIN latest_bases b
          ON b.institutional_filer_id = r.institutional_filer_id
         AND b.period_of_report = r.period_of_report
        WHERE r.status = 'parsed'
          AND (r.filed_at IS NULL OR r.filed_at <= :as_of)
          AND r.amendment_type = 'NEW HOLDINGS'
          AND COALESCE(r.filed_at, TIMESTAMP 'epoch') > b.filed_at
      )
      SELECT i.name AS institution_name,
             i.cik AS institution_cik,
             er.period_of_report,
             MAX(er.filed_at) AS filed_at,
             ms.cusip,
             ms.security_name,
             SUM(h.shares) AS shares,
             SUM(h.value_usd) AS value_usd,
             BOOL_OR(h.suspect) AS suspect
      FROM effective_reports er
      INNER JOIN institutional_filers i ON i.id = er.institutional_filer_id
      INNER JOIN institutional_holdings h ON h.institutional_report_id = er.id
      INNER JOIN mapped_securities ms ON ms.cusip = h.cusip
      GROUP BY i.id, i.name, i.cik, er.period_of_report, ms.cusip, ms.security_name
      ORDER BY er.period_of_report DESC, value_usd DESC NULLS LAST, i.name, ms.cusip
      LIMIT :limit
    SQL
  end

  private

  def select(sql, since:, limit:, periods: 4)
    binds = {
      ticker_pattern: @ticker,
      since:,
      as_of: @as_of,
      limit:,
      periods:
    }
    binds[:ticker_pattern] = "%#{ApplicationRecord.sanitize_sql_like(@ticker)}%"
    ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([ sql, binds ])).to_a
  end
end
