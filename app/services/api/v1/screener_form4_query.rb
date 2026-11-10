# frozen_string_literal: true

module Api
  module V1
    class ScreenerForm4Query
      def initialize(entity:, page:, window_days:)
        @entity = entity
        @page = page
        @window_days = window_days
      end

      def to_sql
        scope = Form4ReadScope.new(as_of: @page.as_of, max_filing_id: @page.bound("filings"), max_transaction_id: @page.bound("transactions"))
        filings = scope.effective_filings
        rows = scope.transactions.select("insider_transactions.*", "filings.filed_at AS known_at")
        companies = @entity == "companies"
        key = companies ? "issuer_cik" : "insider_cik"
        opposite = companies ? "insider_cik" : "issuer_cik"
        identities = if companies
          <<~SQL
            SELECT DISTINCT ON (issuer_cik) issuer_cik AS cik, COALESCE(NULLIF(issuer_name, ''), issuer_cik) AS name,
              UPPER(NULLIF(issuer_ticker, '')) AS ticker, id AS primary_filing_id, filed_at AS last_filed_at
            FROM visible_filings WHERE issuer_cik ~ '^[0-9]{10}$'
            ORDER BY issuer_cik, filed_at DESC, accession_no DESC
          SQL
        else
          <<~SQL
            SELECT DISTINCT ON (insider_cik) insider_cik AS cik, COALESCE(NULLIF(insider_name, ''), insider_cik) AS name,
              filing_id AS primary_filing_id, known_at AS last_filed_at,
              is_director AS latest_is_director, is_officer AS latest_is_officer,
              is_ten_percent_owner AS latest_is_ten_percent_owner, is_other AS latest_is_other,
              officer_title, issuer_cik AS latest_role_issuer_cik
            FROM visible_rows WHERE insider_cik ~ '^[0-9]{10}$'
            ORDER BY insider_cik, known_at DESC, accession_no DESC, id DESC
          SQL
        end
        cutoff = ApplicationRecord.connection.quote(@page.as_of - @window_days.days)
        <<~SQL
          WITH visible_filings AS (#{filings.to_sql}), visible_rows AS (#{rows.to_sql}), identities AS (#{identities}), eligible AS (
            SELECT *, CASE WHEN shares > 0 AND price > 0 AND NOT price_suspect
              AND shares::text NOT IN ('NaN', 'Infinity', '-Infinity') AND price::text NOT IN ('NaN', 'Infinity', '-Infinity')
              THEN shares * price END AS reported_value
            FROM visible_rows WHERE security_table = 'non_derivative' AND transaction_code IN ('P', 'S')
              AND known_at > #{cutoff} #{companies ? 'AND owner_seq = 1' : ''}
          ), metrics AS (
            SELECT #{key} AS cik, COUNT(*) AS open_market_count,
              COUNT(*) FILTER (WHERE transaction_code = 'P') AS purchase_count,
              COUNT(*) FILTER (WHERE transaction_code = 'S') AS sale_count,
              COUNT(DISTINCT #{opposite}) AS #{companies ? 'insider_count' : 'issuer_count'},
              COUNT(*) FILTER (WHERE reported_value IS NULL) AS transactions_without_usable_value,
              CASE WHEN COUNT(*) FILTER (WHERE transaction_code = 'P' AND reported_value IS NULL) = 0
                THEN COALESCE(SUM(reported_value) FILTER (WHERE transaction_code = 'P'), 0) END AS purchase_value,
              CASE WHEN COUNT(*) FILTER (WHERE transaction_code = 'S' AND reported_value IS NULL) = 0
                THEN COALESCE(SUM(reported_value) FILTER (WHERE transaction_code = 'S'), 0) END AS sale_value,
              CASE WHEN COUNT(*) FILTER (WHERE reported_value IS NULL) = 0
                THEN SUM(CASE WHEN transaction_code = 'P' THEN reported_value ELSE -reported_value END) END AS net_open_market_value,
              COUNT(DISTINCT filing_id) AS source_filing_count
            FROM eligible GROUP BY #{key}
          )
          SELECT i.*, i.cik AS event_key, i.last_filed_at::date AS last_filed_on,
            COALESCE(m.open_market_count, 0) AS open_market_count,
            COALESCE(m.purchase_count, 0) AS purchase_count, COALESCE(m.sale_count, 0) AS sale_count,
            COALESCE(m.#{companies ? 'insider_count' : 'issuer_count'}, 0) AS #{companies ? 'insider_count' : 'issuer_count'},
            COALESCE(m.transactions_without_usable_value, 0) AS transactions_without_usable_value,
            CASE WHEN m.cik IS NULL THEN 0 ELSE m.purchase_value END AS purchase_value,
            CASE WHEN m.cik IS NULL THEN 0 ELSE m.sale_value END AS sale_value,
            CASE WHEN m.cik IS NULL THEN 0 ELSE m.net_open_market_value END AS net_open_market_value,
            COALESCE(m.source_filing_count, 0) AS source_filing_count
          FROM identities i LEFT JOIN metrics m ON m.cik = i.cik
        SQL
      end
    end
  end
end
