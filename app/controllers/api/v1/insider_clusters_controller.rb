# frozen_string_literal: true

module Api
  module V1
    class InsiderClustersController < BaseController
      def index
        values = InsiderClustersParameters.normalize(read_parameters(allowed: InsiderClustersParameters::PARAMETERS))
        if values["watchlist_only"] == "true"
          private_response!
          return request_authentication unless Current.user
        end
        context = { "resource" => "insider_clusters" }
        context["user_id"] = Current.user.id if values["watchlist_only"] == "true"
        page = CursorPage.new(parameters: values, context:, sorts: InsiderClustersQuery::SORTS, default_sort: "-window_end",
                              bounds: InsiderClustersQuery::BOUNDS, as_of:)
        result = InsiderClustersQuery.new(page:, filters: values, user: Current.user).call
        serializer = InsiderClusterSerializer.new(rows: result.records, as_of: page.as_of)
        render json: { data: result.records.map { |row| serializer.render(row) },
          meta: result.meta.merge(window_days: ActivityMethodology.window_days, minimum_insiders: values.fetch("min_insiders").to_i,
            definition_minimum_insiders: ActivityMethodology.minimum_insiders) }
      end
    end
  end
end
