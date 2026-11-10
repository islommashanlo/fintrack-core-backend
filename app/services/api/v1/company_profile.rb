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
        scope = InsiderTransactionsQuery.new(parameters: transaction_filters, as_of: @as_of).relation
          .where(owner_seq: 1, security_table: "non_derivative", transaction_code: InsiderTransaction::OPEN_MARKET_CODES)
          .where("filings.filed_at > ?", @as_of - 90.days)
        row = scope.pick(*[
          "COUNT(*) FILTER (WHERE insider_transactions.transaction_code = 'P')",
          "COUNT(*) FILTER (WHERE insider_transactions.transaction_code = 'S')",
          "COUNT(DISTINCT insider_transactions.insider_cik)",
          "SUM(#{InsiderTransactionsQuery::VALUE_SQL}) FILTER (WHERE insider_transactions.transaction_code = 'P')",
          "SUM(#{InsiderTransactionsQuery::VALUE_SQL}) FILTER (WHERE insider_transactions.transaction_code = 'S')"
        ].map { |sql| Arel.sql(sql) })
        { window_days: 90, purchase_count: row[0], sale_count: row[1], insider_count: row[2],
          purchase_value: row[3], sale_value: row[4] }
      end

      def transaction_filters
        { "ticker" => @ticker }.tap { |filters| filters["issuer_cik"] = issuer_cik if issuer_cik }
      end
    end
  end
end
