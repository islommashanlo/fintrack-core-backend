# frozen_string_literal: true

# Read-only discovery queries for the public product surface. Each result is a
# SQL aggregate so a large filing history is never loaded into Ruby to search it.
class DiscoverySearch
  def initialize(query: nil)
    @query = query.to_s.strip
  end

  def institutions(limit: 12)
    select(<<~SQL, limit:)
      SELECT i.id, i.cik, i.name,
             COUNT(r.id) FILTER (WHERE r.status = 'parsed') AS reports,
             MAX(r.period_of_report) FILTER (WHERE r.status = 'parsed') AS latest_period,
             MAX(r.filed_at) FILTER (WHERE r.status = 'parsed') AS last_filed_at
      FROM institutional_filers i
      LEFT JOIN institutional_reports r ON r.institutional_filer_id = i.id
      #{institution_filter}
      GROUP BY i.id
      ORDER BY last_filed_at DESC NULLS LAST, i.name
      LIMIT :limit
    SQL
  end

  def insiders(limit: 12)
    select(<<~SQL, limit:)
      SELECT t.insider_cik,
             (array_agg(t.insider_name ORDER BY f.filed_at DESC NULLS LAST))[1] AS insider_name,
             COUNT(*) AS purchases,
             COUNT(DISTINCT t.issuer_cik) AS issuers,
             MAX(f.filed_at) AS last_filed_at
      FROM insider_transactions t
      INNER JOIN filings f ON f.id = t.filing_id
      WHERE f.parse_status = 'parsed'
        AND t.security_table = 'non_derivative'
        AND t.transaction_code = 'P'
        AND t.owner_seq = 1
        #{insider_filter}
      GROUP BY t.insider_cik
      ORDER BY last_filed_at DESC NULLS LAST, purchases DESC, t.insider_cik
      LIMIT :limit
    SQL
  end

  def issuers(limit: 12)
    select(<<~SQL, limit:)
      SELECT t.issuer_cik,
             (array_agg(f.issuer_name ORDER BY f.filed_at DESC NULLS LAST))[1] AS issuer_name,
             (array_agg(COALESCE(t.issuer_ticker, '') ORDER BY f.filed_at DESC NULLS LAST))[1] AS issuer_ticker,
             COUNT(*) AS purchases,
             COUNT(DISTINCT t.insider_cik) AS insiders,
             MAX(f.filed_at) AS last_filed_at
      FROM insider_transactions t
      INNER JOIN filings f ON f.id = t.filing_id
      WHERE f.parse_status = 'parsed'
        AND t.security_table = 'non_derivative'
        AND t.transaction_code = 'P'
        AND t.owner_seq = 1
        #{issuer_filter}
      GROUP BY t.issuer_cik
      ORDER BY last_filed_at DESC NULLS LAST, purchases DESC, t.issuer_cik
      LIMIT :limit
    SQL
  end

  private

  def select(sql, limit:)
    binds = { limit: }
    binds[:pattern] = "%#{ApplicationRecord.sanitize_sql_like(@query)}%" if @query.present?
    ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([ sql, binds ])).to_a
  end

  def institution_filter
    return "" if @query.blank?

    "WHERE i.name ILIKE :pattern OR i.cik ILIKE :pattern"
  end

  def insider_filter
    return "" if @query.blank?

    "AND (t.insider_name ILIKE :pattern OR t.insider_cik ILIKE :pattern)"
  end

  def issuer_filter
    return "" if @query.blank?

    "AND (f.issuer_name ILIKE :pattern OR t.issuer_ticker ILIKE :pattern OR t.issuer_cik ILIKE :pattern)"
  end
end
