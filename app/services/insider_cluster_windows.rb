# frozen_string_literal: true

class InsiderClusterWindows
  def self.source(as_of:, max_filing_id: nil, max_transaction_id: nil)
    Form4ReadScope.new(as_of:, max_filing_id:, max_transaction_id:).transactions
      .where(owner_seq: 1, security_table: "non_derivative", transaction_code: InsiderTransaction::OPEN_MARKET_CODES)
      .select("insider_transactions.*", "filings.filed_at AS known_at", "filings.issuer_name",
        "COALESCE(NULLIF(insider_transactions.issuer_ticker, ''), filings.issuer_ticker) AS reported_ticker",
        "#{Api::V1::InsiderTransactionsQuery::VALUE_SQL} AS reported_value")
  end

  def self.sql(source:, from:, to:, min_insiders: ActivityMethodology.minimum_insiders)
    ApplicationRecord.sanitize_sql([ <<~SQL, from:, to:, min_insiders: ])
      WITH eligible AS (#{source.to_sql}), anchors AS (
        SELECT DISTINCT issuer_cik, transaction_code, known_at AS window_end
        FROM eligible WHERE known_at >= :from AND known_at < :to
      ), clusters AS (
        SELECT a.issuer_cik, a.transaction_code,
          a.window_end - INTERVAL '#{ActivityMethodology.window_days} days' AS window_start, a.window_end,
          COUNT(DISTINCT t.insider_cik) AS insider_count, COUNT(*) AS transaction_count,
          SUM(t.reported_value) AS known_value_subtotal,
          CASE WHEN COUNT(*) = COUNT(t.reported_value) THEN SUM(t.reported_value) END AS total_value,
          COUNT(*) FILTER (WHERE t.reported_value IS NULL) AS transactions_without_usable_price,
          ARRAY_AGG(t.id ORDER BY t.id) AS transaction_ids,
          ARRAY_AGG(DISTINCT t.insider_cik ORDER BY t.insider_cik) AS insider_ciks,
          ARRAY_AGG(DISTINCT t.filing_id ORDER BY t.filing_id) AS filing_ids,
          (ARRAY_AGG(t.filing_id ORDER BY t.known_at DESC, t.accession_no DESC, t.id DESC))[1] AS primary_filing_id,
          (ARRAY_AGG(t.issuer_name ORDER BY t.known_at DESC, t.accession_no DESC, t.id DESC))[1] AS issuer_name,
          (ARRAY_AGG(t.reported_ticker ORDER BY t.known_at DESC, t.accession_no DESC, t.id DESC))[1] AS issuer_ticker
        FROM anchors a INNER JOIN eligible t ON t.issuer_cik = a.issuer_cik AND t.transaction_code = a.transaction_code
          AND t.known_at > a.window_end - INTERVAL '#{ActivityMethodology.window_days} days' AND t.known_at <= a.window_end
        GROUP BY a.issuer_cik, a.transaction_code, a.window_end
        HAVING COUNT(DISTINCT t.insider_cik) >= :min_insiders
      )
      SELECT clusters.*, encode(sha256(convert_to(jsonb_build_array(clusters.issuer_cik, clusters.transaction_code,
        clusters.window_end, #{ActivityMethodology.window_days}, #{ActivityMethodology.minimum_insiders},
        clusters.transaction_ids)::text, 'UTF8')), 'hex') AS event_key, names.insiders
      FROM clusters
      LEFT JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object('cik', insider_cik, 'name', insider_name) ORDER BY insider_cik) AS insiders
        FROM (
          SELECT DISTINCT ON (t.insider_cik) t.insider_cik, t.insider_name
          FROM eligible t WHERE t.id = ANY(clusters.transaction_ids)
          ORDER BY t.insider_cik, t.known_at DESC, t.accession_no DESC, t.id DESC
        ) latest_names
      ) names ON TRUE
    SQL
  end
end
