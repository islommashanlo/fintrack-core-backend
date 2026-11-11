# frozen_string_literal: true

module Api
  module V1
    class CompaniesController < BaseController
      prepend_before_action :private_response!, only: %i[institutional history prices news]

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
        history = HistoryWindow.new(limit: PlanCatalog.limit_for(Current.user, :history_quarters), user_id: Current.user&.id)
        page = CursorPage.new(parameters: values, context: history.context.merge("resource" => "company_institutional", "ticker" => company.ticker),
                              sorts: InstitutionalHoldingsQuery::SORTS, default_sort: "-value_usd",
                              bounds: InstitutionalHoldingsQuery::BOUNDS.merge("mappings" => CusipSecurityMapping), as_of:)
        history.check!(period, as_of: page.as_of)
        scope = InstitutionalHoldingsQuery.new(page:, filters: values).for_company(company.ticker, period:)
        result = history.preview(page:, scope:, allowed_scope: history.holdings(scope, as_of: page.as_of),
          preload: [ { institutional_report: [ :filing, :institutional_filer ] } ])
        render_read_page(result, InstitutionalHoldingSerializer)
      end

      def history
        values = read_parameters(allowed: %w[period cusip put_call share_type sort limit cursor], path_keys: [ :ticker ])
        period_parameter(values["period"])
        InstitutionalHoldingsQuery.validate_filters!(values)
        history = HistoryWindow.new(limit: PlanCatalog.limit_for(Current.user, :history_quarters), user_id: Current.user&.id)
        page = CursorPage.new(parameters: values, context: history.context.merge("resource" => "company_history", "ticker" => company.ticker),
          sorts: CompanyHistoryQuery::SORTS, default_sort: "-period", bounds: CompanyHistoryQuery::BOUNDS, as_of:)
        result = CompanyHistoryQuery.new(ticker: company.ticker, page:, filters: values, history:).call
        serializer = CompanyHistorySerializer.new(rows: result.records, ticker: company.ticker, as_of: page.as_of, filters: values)
        render json: { data: result.records.map { |row| serializer.render(row) }, meta: result.meta }
      end

      def prices
        values = read_parameters(allowed: CompanyPricesQuery::PARAMETERS, path_keys: [ :ticker ])
        render json: CompanyPricesQuery.new(company:, parameters: values, as_of:).call
      end

      def news
        values = read_parameters(allowed: NewsQuery::PARAMETERS, path_keys: [ :ticker ])
        render json: NewsQuery.new(parameters: values, target: { role: "issuer", cik: company.issuer_cik }, as_of:).call
      end

      private

      def company
        @company ||= CompanyProfile.new(ticker: params[:ticker], as_of:)
      end
    end
  end
end
