# frozen_string_literal: true

module Api
  module V1
    class InsidersController < BaseController
      prepend_before_action :private_response!, only: :news

      def show
        read_parameters(allowed: [], path_keys: [ :cik ])
        render json: { data: InsiderProfileSerializer.render(insider, as_of:) }
      end

      def transactions
        values = read_parameters(allowed: InsiderTransactionsQuery::PARAMETERS - %w[insider_cik], path_keys: [ :cik ])
        result = InsiderTransactionsQuery.new(parameters: values.merge("insider_cik" => insider.cik), as_of:).call
        render_read_page(result, InsiderTransactionSerializer)
      end

      def companies
        values = read_parameters(allowed: InsiderCompaniesQuery::FILTERS + %w[sort limit cursor], path_keys: [ :cik ])
        InsiderCompaniesQuery.normalize_filters!(values)
        page = CursorPage.new(parameters: values, context: { "resource" => "insider_companies", "cik" => insider.cik },
                              sorts: InsiderCompaniesQuery::SORTS, default_sort: "-filed_at",
                              bounds: { "filings" => Filing, "transactions" => InsiderTransaction }, as_of:)
        result = InsiderCompaniesQuery.new(cik: insider.cik, page:, filters: values).call
        render_read_page(result, InsiderCompanySerializer)
      end

      def news
        values = read_parameters(allowed: NewsQuery::PARAMETERS, path_keys: [ :cik ])
        render json: NewsQuery.new(parameters: values, target: { role: "person", cik: insider.cik }, as_of:).call
      end

      private

      def insider
        @insider ||= InsiderProfile.new(cik: params[:cik], as_of:)
      end
    end
  end
end
