# frozen_string_literal: true

module Api
  module V1
    class AlertEventsController < ProtectedController
      def index
        filters = AlertParameters.normalize(read_parameters(allowed: AlertParameters::EVENTS), kind: :events)
        page = CursorPage.new(parameters: filters, context: { "resource" => "alert_events", "user_id" => Current.user.id },
          sorts: AlertEventsQuery::SORTS, default_sort: "-created_at", bounds: AlertEventsQuery::BOUNDS, as_of:)
        result = AlertEventsQuery.call(user: Current.user, page:, filters:)
        serializer = AlertEventSerializer.new(deliveries: result.records, as_of: page.as_of)
        render json: { data: result.records.map { |delivery| serializer.render(delivery) },
          meta: result.meta.merge(AlertCapabilities.for_user(Current.user)) }
      end

      def summary
        read_parameters(allowed: [])
        render json: { data: AlertInboxSummary.call(user: Current.user, as_of:) }
      end

      def read
        read_parameters(allowed: [], path_keys: [ :id ])
        state = AlertEventReads.mark(user: Current.user, id: AlertParameters.id!(params[:id]))
        render json: { data: { id: state.alert_delivery_id, read_at: state.read_at } }
      end

      def read_all
        read_parameters(allowed: [])
        render json: { data: AlertEventReads.mark_all(user: Current.user) }
      end
    end
  end
end
