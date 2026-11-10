# frozen_string_literal: true

module Api
  module V1
    class InsiderCompaniesQuery
      SORTS = {
        "filed_at" => "filings.filed_at", "name" => "LOWER(filings.issuer_name)",
        "ticker" => "filings.issuer_ticker", "cik" => "filings.issuer_cik"
      }.freeze
      FILTERS = %w[ticker role].freeze

      def initialize(cik:, page:, filters:)
        @cik = cik
        @page = page
        @filters = filters
        @scope = Form4ReadScope.new(as_of: page.as_of, max_filing_id: page.bound("filings"),
                                    max_transaction_id: page.bound("transactions"))
      end

      def self.normalize_filters!(values)
        if values["ticker"]
          values["ticker"] = values["ticker"].upcase
          raise InvalidParameter, "Invalid ticker parameter" unless values["ticker"].match?(/\A[A-Z0-9][A-Z0-9.-]{0,19}\z/)
        end
        if values["role"] && !InsiderTransactionsQuery::ROLE_COLUMNS.key?(values["role"])
          raise InvalidParameter, "Invalid role parameter"
        end
      end

      def call
        # Associations are historical disclosures, not a claim of current employment.
        owner_filings = @scope.owner_filings(@cik).where.not(issuer_cik: [ nil, "" ])
          .select("DISTINCT ON (filings.issuer_cik) filings.id")
          .order(Arel.sql("filings.issuer_cik, filings.filed_at DESC, filings.accession_no DESC"))
        sql = ApplicationRecord.sanitize_sql([ <<~SQL, cik: @cik, max_id: @page.bound("transactions") ])
          SELECT filings.*, role.is_director, role.is_officer, role.is_ten_percent_owner,
                 role.is_other, role.officer_title
          FROM filings
          LEFT JOIN LATERAL (
            SELECT is_director, is_officer, is_ten_percent_owner, is_other, officer_title
            FROM insider_transactions
            WHERE filing_id = filings.id AND insider_cik = :cik AND id <= :max_id
            ORDER BY id DESC LIMIT 1
          ) role ON TRUE
          WHERE filings.id IN (#{owner_filings.to_sql})
        SQL
        scope = Filing.from("(#{sql}) filings")
        scope = scope.where("UPPER(filings.issuer_ticker) = ?", @filters["ticker"]) if @filters["ticker"]
        scope = scope.where(InsiderTransactionsQuery::ROLE_COLUMNS.fetch(@filters["role"]) => true) if @filters["role"]
        @page.call(scope)
      end
    end
  end
end
