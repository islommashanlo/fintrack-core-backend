# frozen_string_literal: true

module Api
  module V1
    class CompanyProfile
      attr_reader :ticker, :filing, :security

      def initialize(ticker:, as_of: Time.current)
        @ticker = ticker.to_s.upcase
        raise InvalidParameter, "Invalid ticker parameter" unless @ticker.match?(/\A[A-Z0-9][A-Z0-9.-]{0,19}\z/)

        @as_of = as_of
        @filing = Filing.form4.parsed.where("UPPER(issuer_ticker) = ? AND filed_at <= ?", @ticker, as_of)
          .order(filed_at: :desc, accession_no: :desc).first
        @security = Security.where("UPPER(ticker) = ?", @ticker).where(id: CusipSecurityMapping
          .where(status: "mapped").where("first_seen_at <= ?", as_of).select(:security_id))
          .order(id: :desc).first unless @filing
        raise ActiveRecord::RecordNotFound unless @filing || @security
      end

      def issuer_cik
        @filing&.issuer_cik
      end

      def name
        @filing&.issuer_name || @security&.name
      end

      def summary
        summaries.find { |row| row.fetch("window_days") == 90 }
          .slice("window_days", "purchase_count", "sale_count", "insider_count", "purchase_value", "sale_value").symbolize_keys
      end

      def summaries
        @summaries ||= begin
          transactions = InsiderTransactionsQuery.new(parameters: transaction_filters, as_of: @as_of).relation
            .where(owner_seq: 1, security_table: "non_derivative")
            .where("filings.filed_at > ?", @as_of - 365.days)
            .select("insider_transactions.*", "filings.filed_at AS known_filed_at",
              "#{InsiderTransactionsQuery::VALUE_SQL} AS reported_value")
          sql = ApplicationRecord.sanitize_sql([ <<~SQL, as_of: @as_of ])
            WITH transactions AS (#{transactions.to_sql}), windows(days) AS (VALUES (30), (90), (365))
            SELECT windows.days AS window_days,
              COUNT(t.id) FILTER (WHERE t.transaction_code = 'P') AS purchase_count,
              COUNT(t.id) FILTER (WHERE t.transaction_code = 'S') AS sale_count,
              COUNT(DISTINCT t.insider_cik) FILTER (WHERE t.transaction_code IN ('P', 'S')) AS insider_count,
              SUM(t.reported_value) FILTER (WHERE t.transaction_code = 'P') AS purchase_value,
              SUM(t.reported_value) FILTER (WHERE t.transaction_code = 'S') AS sale_value,
              COUNT(t.id) FILTER (WHERE t.transaction_code IN ('P', 'S') AND t.reported_value IS NULL) AS transactions_without_usable_price,
              CASE WHEN COUNT(t.id) FILTER (WHERE t.transaction_code IN ('P', 'S') AND t.reported_value IS NULL) = 0
                THEN SUM(CASE WHEN t.transaction_code = 'P' THEN t.reported_value
                              WHEN t.transaction_code = 'S' THEN -t.reported_value END)
              END AS net_open_market_value,
              (SELECT COALESCE(jsonb_object_agg(code, count), '{}'::jsonb) FROM (
                SELECT COALESCE(transaction_code, 'unknown') AS code, COUNT(*) AS count
                FROM transactions
                WHERE known_filed_at > :as_of::timestamp - windows.days * INTERVAL '1 day'
                GROUP BY transaction_code
              ) counts) AS counts_by_code
            FROM windows LEFT JOIN transactions t
              ON t.known_filed_at > :as_of::timestamp - windows.days * INTERVAL '1 day'
            GROUP BY windows.days ORDER BY windows.days
          SQL
          CursorPage.sql_rows(sql)
        end
      end

      def transaction_filters
        { "ticker" => @ticker }.tap { |filters| filters["issuer_cik"] = issuer_cik if issuer_cik }
      end
    end
  end
end
