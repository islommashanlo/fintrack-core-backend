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
        source = InsiderClusterWindows.source(as_of: @page.as_of, max_filing_id: @page.bound("filings"),
          max_transaction_id: @page.bound("transactions"))
        source = source.where(issuer_cik: @filters["issuer_cik"]) if @filters["issuer_cik"]
        to = @filters["date_to"] ? Date.iso8601(@filters["date_to"]).next_day.beginning_of_day : @page.as_of + 1.second
        from = @filters["date_from"] ? Date.iso8601(@filters["date_from"]).beginning_of_day : ([ to, @page.as_of ].min - 90.days).beginning_of_day
        source = source.where("filings.filed_at > ?", from - ActivityMethodology.window_days.days)
        source = source.where(transaction_code: @filters["direction"] == "purchase" ? "P" : "S") unless @filters["direction"] == "all"
        filters = []
        filters << "UPPER(clusters.issuer_ticker) = :ticker" if @filters["ticker"]
        filters << "clusters.total_value >= :min_value" if @filters["min_value"]
        filters << watchlist_sql if @filters["watchlist_only"] == "true"
        windows = InsiderClusterWindows.sql(source:, from:, to:, min_insiders: @filters.fetch("min_insiders").to_i)
        ApplicationRecord.sanitize_sql([ <<~SQL, ticker: @filters["ticker"], min_value: @filters["min_value"] ])
          SELECT clusters.* FROM (#{windows}) clusters
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
