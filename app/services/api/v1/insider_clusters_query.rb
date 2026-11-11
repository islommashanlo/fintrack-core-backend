# frozen_string_literal: true

module Api
  module V1
    class InsiderClustersQuery
      BOUNDS = { "filings" => Filing, "transactions" => InsiderTransaction, "follows" => Follow }.freeze
      SORTS = {
        "window_end" => "activity.window_end", "insider_count" => "activity.insider_count",
        "transaction_count" => "activity.transaction_count", "total_value" => "activity.total_value"
      }.freeze

      def initialize(page:, filters:, user: nil)
        @page = page
        @filters = filters
        @user = user
      end

      def call
        @page.call_sql(sql)
      end

      private

      def sql
        source = Form4ReadScope.new(as_of: @page.as_of, max_filing_id: @page.bound("filings"),
                                    max_transaction_id: @page.bound("transactions")).transactions
          .where(owner_seq: 1, security_table: "non_derivative", transaction_code: InsiderTransaction::OPEN_MARKET_CODES)
        source = source.where(issuer_cik: @filters["issuer_cik"]) if @filters["issuer_cik"]
        to = @filters["date_to"] ? Date.iso8601(@filters["date_to"]).next_day.beginning_of_day : @page.as_of + 1.second
        from = @filters["date_from"] ? Date.iso8601(@filters["date_from"]).beginning_of_day : ([ to, @page.as_of ].min - 90.days).beginning_of_day
        source = source.where("filings.filed_at > ?", from - ActivityMethodology.window_days.days)
        source = source.where(transaction_code: @filters["direction"] == "purchase" ? "P" : "S") unless @filters["direction"] == "all"
        source = source.select("insider_transactions.*", "filings.filed_at AS known_at", "filings.issuer_name",
          "COALESCE(NULLIF(insider_transactions.issuer_ticker, ''), filings.issuer_ticker) AS reported_ticker",
          "#{InsiderTransactionsQuery::VALUE_SQL} AS reported_value")
        filters = []
        filters << "UPPER(clusters.issuer_ticker) = :ticker" if @filters["ticker"]
        filters << "clusters.total_value >= :min_value" if @filters["min_value"]
        filters << watchlist_sql if @filters["watchlist_only"] == "true"
        binds = { from:, to:, min_insiders: @filters.fetch("min_insiders").to_i,
                  ticker: @filters["ticker"], min_value: @filters["min_value"] }
        ApplicationRecord.sanitize_sql([ <<~SQL, binds ])
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
          #{filters.empty? ? '' : "WHERE #{filters.join(' AND ')}"}
        SQL
      end

      def watchlist_sql
        ApplicationRecord.sanitize_sql([ <<~SQL, user_id: @user.id, max_follow: @page.bound("follows"), max_tx: @page.bound("transactions"), snapshot: @page.as_of ])
          EXISTS (SELECT 1 FROM follows WHERE follows.user_id = :user_id AND follows.removed_at IS NULL AND follows.followed_at <= :snapshot AND follows.id <= :max_follow AND (
            (follows.target_type = 'Ticker' AND follows.target_key = UPPER(clusters.issuer_ticker))
            OR (follows.target_type = 'Insider' AND EXISTS (
              SELECT 1 FROM insider_transactions canonical INNER JOIN insider_transactions owners
                ON owners.filing_id = canonical.filing_id AND owners.security_table = canonical.security_table AND owners.txn_seq = canonical.txn_seq
              WHERE canonical.id = ANY(clusters.transaction_ids) AND owners.id <= :max_tx AND owners.insider_cik = follows.target_key
            ))
          ))
        SQL
      end
    end
  end
end
