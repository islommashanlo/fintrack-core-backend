# frozen_string_literal: true

module Api
  module V1
    class InsiderProfile
      attr_reader :cik, :name, :latest_filing

      def initialize(cik:, as_of: Time.current)
        @cik = cik.to_s
        raise InvalidParameter, "Invalid cik parameter" unless @cik.match?(/\A\d{10}\z/)

        @as_of = as_of
        @scope = Form4ReadScope.new(as_of:)
        @latest_filing = @scope.owner_filings(@cik).order(filed_at: :desc, accession_no: :desc).first
        raise ActiveRecord::RecordNotFound unless @latest_filing

        latest_row = @scope.transactions(effective: false).where(insider_cik: @cik)
          .order(Arel.sql("filings.filed_at DESC, filings.accession_no DESC, insider_transactions.id DESC"))
          .pick(:insider_name)
        @name = latest_row.presence || Filer.find_by(cik: @cik)&.name
      end

      def summaries
        transactions = @scope.transactions.where(insider_cik: @cik, security_table: "non_derivative")
          .select("insider_transactions.*", "filings.filed_at AS known_filed_at",
                  "#{InsiderTransactionsQuery::VALUE_SQL} AS reported_value")
        sql = ApplicationRecord.sanitize_sql([ <<~SQL, as_of: @as_of ])
          WITH transactions AS (#{transactions.to_sql}), windows(days) AS (VALUES (30), (90), (365))
          SELECT windows.days AS window_days,
            COUNT(t.id) FILTER (WHERE t.transaction_code = 'P') AS purchase_count,
            COUNT(t.id) FILTER (WHERE t.transaction_code = 'S') AS sale_count,
            COUNT(DISTINCT t.issuer_cik) AS issuer_count,
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
        ApplicationRecord.connection.select_all(sql).to_a.map do |row|
          row.merge("counts_by_code" => JSON.parse(row.fetch("counts_by_code")))
        end
      end
    end
  end
end
