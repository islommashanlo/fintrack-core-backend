# frozen_string_literal: true

module Api
  module V1
    class ScreenerController < BaseController
      before_action :private_response!

      def run
        values = ScreenerParameters.normalize(params.except(:controller, :action, :format).to_unsafe_h)
        maximum = PlanCatalog.limit_for(Current.user, :screener_results)
        page = CursorPage.new(parameters: values,
          context: { "resource" => "screener", "user_id" => Current.user&.id, "maximum_records" => maximum },
          sorts: ScreenerDefinition.sorts(values.fetch("entity")), default_sort: "name", bounds: ScreenerQuery::BOUNDS, as_of:)
        result = ScreenerQuery.call(page:, values:, maximum_records: maximum)
        serializer = ScreenerResultSerializer.new(rows: result.records, entity: values.fetch("entity"), as_of: page.as_of,
          window_days: values["window_days"]&.to_i)
        render json: { data: result.records.map { |row| serializer.render(row) }, meta: result.meta }
      end
    end
  end
end
