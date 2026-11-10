# frozen_string_literal: true

module Api
  module V1
    class CompaniesController < BaseController
      def show
        read_parameters(allowed: [], path_keys: [ :ticker ])
        render json: { data: CompanySerializer.render(company, as_of:) }
      end

      def insiders
        values = read_parameters(allowed: InsiderTransactionsQuery::PARAMETERS - %w[ticker issuer_cik], path_keys: [ :ticker ])
        result = InsiderTransactionsQuery.new(parameters: values.merge(company.transaction_filters), as_of:).call
        render_read_page(result, InsiderTransactionSerializer)
      end

      def filings
        values = read_parameters(allowed: %w[form_type sort limit cursor], path_keys: [ :ticker ])
        if values["form_type"] && !Filing::FORM4_TYPES.include?(values["form_type"])
          raise InvalidParameter, "Invalid form_type parameter"
        end
        page = CursorPage.new(parameters: values, context: {
          "resource" => "company_filings", "ticker" => company.ticker, "issuer_cik" => company.issuer_cik
        },
                              sorts: { "filed_at" => "filings.filed_at", "period" => "filings.period_of_report" },
                              default_sort: "-filed_at", bounds: { "filings" => Filing }, as_of:)
        scope = Filing.form4.parsed.where("UPPER(issuer_ticker) = ? AND filed_at <= ? AND id <= ?",
                                         company.ticker, page.as_of, page.bound("filings"))
        scope = scope.where(issuer_cik: company.issuer_cik) if company.issuer_cik
        scope = scope.where(form_type: values["form_type"]) if values["form_type"]
        render_read_page(page.call(scope), FilingSummarySerializer)
      end

      def institutional
        values = read_parameters(allowed: %w[period cusip put_call share_type sort limit cursor], path_keys: [ :ticker ])
        period = period_parameter(values["period"])
        InstitutionalHoldingsQuery.validate_filters!(values)
        page = CursorPage.new(parameters: values, context: { "resource" => "company_institutional", "ticker" => company.ticker },
                              sorts: InstitutionalHoldingsQuery::SORTS, default_sort: "-value_usd",
                              bounds: InstitutionalHoldingsQuery::BOUNDS.merge("mappings" => CusipSecurityMapping), as_of:)
        scope = InstitutionalHoldingsQuery.new(page:, filters: values).for_company(company.ticker, period:)
        result = page.call(scope, preload: [ { institutional_report: [ :filing, :institutional_filer ] } ])
        render_read_page(result, InstitutionalHoldingSerializer)
      end

      private

      def company
        @company ||= CompanyProfile.new(ticker: params[:ticker], as_of:)
      end
    end
  end
end
