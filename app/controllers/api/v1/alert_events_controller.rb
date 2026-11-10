# frozen_string_literal: true

module Api
  module V1
    class AlertEventsController < ProtectedController
      def index
        filters = AlertParameters.normalize(read_parameters(allowed: AlertParameters::EVENTS), kind: :events)
        page = CursorPage.new(parameters: filters, context: { "resource" => "alert_events", "user_id" => Current.user.id },
          sorts: AlertEventsQuery::SORTS, default_sort: "-created_at", bounds: AlertEventsQuery::BOUNDS, as_of:)
        result = AlertEventsQuery.call(user: Current.user, page:, filters:)
        render json: { data: result.records.map { |delivery| AlertEventSerializer.render(delivery, as_of: page.as_of) },
          meta: result.meta.merge(AlertCapabilities.for_user(Current.user)) }
      end
    end
  end
end
