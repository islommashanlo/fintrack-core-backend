# frozen_string_literal: true

# Read-only, point-in-time Form 4 queries for an insider profile. Amendments
# supersede their original rows through the same SQL rule used by InsiderSignals.
class InsiderProfile
  VALUE = "t.shares * t.price"
  USABLE_PRICE = "t.price IS NOT NULL AND NOT t.price_suspect"
  TRANSACTIONS = <<~SQL
    FROM insider_transactions t
    INNER JOIN filings f ON f.id = t.filing_id
    WHERE f.parse_status = 'parsed'
      AND t.insider_cik = :insider_cik
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

  def initialize(insider_cik:, as_of: Time.current)
    @insider_cik = insider_cik
    @as_of = as_of
  end

  def name
    select(<<~SQL, since: @as_of - 365.days, limit: 1).first&.fetch("insider_name", nil)
      SELECT t.insider_name
      #{TRANSACTIONS}
      ORDER BY f.filed_at DESC, t.txn_seq
      LIMIT :limit
    SQL
  end

  def summary(days: 90)
    select(<<~SQL, since: @as_of - days.days, limit: 1).first || {}
      SELECT COUNT(*) FILTER (WHERE t.transaction_code = 'P') AS purchase_count,
             COUNT(*) FILTER (WHERE t.transaction_code = 'S') AS sale_count,
             COUNT(DISTINCT t.issuer_cik) AS issuer_count,
             SUM(#{VALUE}) FILTER (WHERE t.transaction_code = 'P' AND #{USABLE_PRICE}) AS purchase_value,
             COUNT(*) FILTER (WHERE t.transaction_code = 'P' AND NOT (#{USABLE_PRICE})) AS purchases_without_usable_price,
             MAX(f.filed_at) AS last_filed_at
      #{TRANSACTIONS}
    SQL
  end

  def transactions(days: 365, limit: 40)
    select(<<~SQL, since: @as_of - days.days, limit:)
      SELECT f.filed_at, f.accession_no, f.issuer_cik, f.issuer_name, f.issuer_ticker,
             t.insider_name, t.transaction_date, t.transaction_code, t.shares, t.price,
             t.price_suspect, t.acquired_disposed, t.security_title,
             CASE WHEN #{USABLE_PRICE} THEN #{VALUE} END AS value
      #{TRANSACTIONS}
      ORDER BY f.filed_at DESC, f.accession_no, t.txn_seq
      LIMIT :limit
    SQL
  end

  def issuer_activity(days: 730, limit: 12)
    select(<<~SQL, since: @as_of - days.days, limit:)
      SELECT t.issuer_cik,
             (array_agg(f.issuer_name ORDER BY f.filed_at DESC NULLS LAST))[1] AS issuer_name,
             (array_agg(COALESCE(NULLIF(t.issuer_ticker, ''), f.issuer_ticker)
                        ORDER BY f.filed_at DESC NULLS LAST))[1] AS issuer_ticker,
             COUNT(*) FILTER (WHERE t.transaction_code = 'P') AS purchase_count,
             COUNT(*) FILTER (WHERE t.transaction_code = 'S') AS sale_count,
             SUM(#{VALUE}) FILTER (WHERE t.transaction_code = 'P' AND #{USABLE_PRICE}) AS purchase_value,
             MAX(f.filed_at) AS last_filed_at
      #{TRANSACTIONS}
      GROUP BY t.issuer_cik
      ORDER BY last_filed_at DESC NULLS LAST, purchase_count DESC, t.issuer_cik
      LIMIT :limit
    SQL
  end

  private

  def select(sql, since:, limit:)
    binds = { insider_cik: @insider_cik, since:, as_of: @as_of, limit: }
    ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([ sql, binds ])).to_a
  end
end
