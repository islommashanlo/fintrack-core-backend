# frozen_string_literal: true

module Api
  module V1
    class ActivityController < BaseController
      def index
        values = ActivityParameters.normalize(read_parameters(allowed: ActivityParameters::PARAMETERS))
        if values["watchlist_only"] == "true"
          private_response!
          return request_authentication unless Current.user
        end
        page = activity_page(values)
        result = ActivityQuery.new(page:, filters: values, user: Current.user).call
        serializer = ActivitySerializer.new(rows: result.records, as_of: page.as_of)
        render json: {
          data: result.records.map { |row| serializer.render(row) },
          meta: result.meta.merge(available_sources: %w[insider institutional], scoring_available: false, sector_available: false)
        }
      end

      def show
        read_parameters(allowed: [], path_keys: [ :id ])
        identifier = ActivityIdentifier.decode(params[:id])
        page = activity_page({})
        row = ActivityQuery.new(page:).find(identifier)
        scoring_bounds = { "filings" => page.bound("filings"), "transactions" => page.bound("transactions") }
        render json: { data: ActivitySerializer.new(rows: [ row ], as_of:, scoring_bounds:).render(row) }
      end

      private

      def activity_page(values)
        context = { "resource" => "activity" }
        context["user_id"] = Current.user.id if values["watchlist_only"] == "true"
        CursorPage.new(parameters: values, context:, sorts: ActivityQuery::SORTS, default_sort: "-occurred_at",
                       bounds: ActivityQuery::BOUNDS, as_of:)
      end
    end
  end
end
