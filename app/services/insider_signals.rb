# frozen_string_literal: true

# Signal queries over Form 4 open-market purchases. All set logic is SQL (invariant 8).
#
# Rules every query shares:
# - Point in time (invariant 5): windows and "as of" are measured on filings.filed_at,
#   the moment the SEC accepted the filing, never on the transaction or period date.
# - A filing is left out once an amendment to it had been filed by the as-of time.
#   Both filings stay in the database (invariant 4).
# - Only the non-derivative table and transaction code P count as purchases.
# - A joint filing reports the same trade once per reporting owner. Only the first-listed
#   owner's row is used, so a trade is counted once and joint filers are one buyer.
# - Values use shares * price, skipping rows whose price is missing or flagged
#   price_suspect. Those rows still count as purchases.
class InsiderSignals
  PURCHASES = <<~SQL
    FROM insider_transactions t
    JOIN filings f ON f.id = t.filing_id
    WHERE f.parse_status = 'parsed'
      AND t.security_table = 'non_derivative'
      AND t.transaction_code = 'P'
      AND t.owner_seq = 1
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

  VALUE = "t.shares * t.price"
  USABLE_PRICE = "t.price IS NOT NULL AND NOT t.price_suspect"

  def initialize(as_of: Time.current)
    @as_of = as_of
  end

  # One line per purchase, newest filing first.
  def recent_purchases(days: 7, limit: 50)
    query(<<~SQL, days:, limit:)
      SELECT f.filed_at, f.accession_no, f.issuer_cik, f.issuer_name, f.issuer_ticker,
             t.insider_cik, t.insider_name, t.officer_title, t.is_director, t.is_officer,
             t.is_ten_percent_owner, t.transaction_date, t.shares, t.price, t.price_suspect,
             CASE WHEN #{USABLE_PRICE} THEN #{VALUE} END AS value,
             cardinality(f.owner_ciks) AS reporting_owners
      #{PURCHASES}
      ORDER BY f.filed_at DESC, f.accession_no, t.txn_seq
      LIMIT :limit
    SQL
  end

  # Issuers where several different insiders filed purchases inside the window.
  def cluster_buys(days: 30, min_insiders: 2, limit: 50)
    query(<<~SQL, days:, limit:, min_insiders:)
      SELECT t.issuer_cik,
             (array_agg(f.issuer_name ORDER BY f.filed_at DESC))[1] AS issuer_name,
             (array_agg(f.issuer_ticker ORDER BY f.filed_at DESC))[1] AS issuer_ticker,
             COUNT(DISTINCT t.insider_cik) AS insiders,
             COUNT(*) AS purchases,
             SUM(t.shares) AS shares,
             SUM(#{VALUE}) FILTER (WHERE #{USABLE_PRICE}) AS value,
             COUNT(*) FILTER (WHERE NOT (#{USABLE_PRICE})) AS purchases_without_usable_price,
             MIN(f.filed_at) AS first_filed_at,
             MAX(f.filed_at) AS last_filed_at
      #{PURCHASES}
      GROUP BY t.issuer_cik
      HAVING COUNT(DISTINCT t.insider_cik) >= :min_insiders
      ORDER BY insiders DESC, value DESC NULLS LAST, t.issuer_cik
      LIMIT :limit
    SQL
  end

  # Insiders ranked by the value of purchases they filed inside the window.
  def top_insiders(days: 90, limit: 25)
    query(<<~SQL, days:, limit:)
      SELECT t.insider_cik,
             (array_agg(t.insider_name ORDER BY f.filed_at DESC))[1] AS insider_name,
             COUNT(*) AS purchases,
             COUNT(DISTINCT t.issuer_cik) AS issuers,
             SUM(#{VALUE}) FILTER (WHERE #{USABLE_PRICE}) AS value,
             COUNT(*) FILTER (WHERE NOT (#{USABLE_PRICE})) AS purchases_without_usable_price,
             MAX(f.filed_at) AS last_filed_at
      #{PURCHASES}
      GROUP BY t.insider_cik
      ORDER BY value DESC NULLS LAST, purchases DESC, t.insider_cik
      LIMIT :limit
    SQL
  end

  private

  def query(sql, days:, **binds)
    binds = binds.merge(as_of: @as_of, since: @as_of - days.days)

    ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([ sql, binds ])).to_a
  end
end
