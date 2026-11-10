# frozen_string_literal: true

module Api
  module V1
    class AlertRulesController < ProtectedController
      def index
        filters = AlertParameters.normalize(read_parameters(allowed: AlertParameters::RULES), kind: :rules)
        page = CursorPage.new(parameters: filters, context: { "resource" => "alert_rules", "user_id" => Current.user.id },
          sorts: AlertRulesQuery::SORTS, default_sort: "-created_at", bounds: AlertRulesQuery::BOUNDS, as_of:)
        result = AlertRulesQuery.call(user: Current.user, page:, filters:)
        render json: { data: result.records.map { |rule| AlertRuleSerializer.render(rule) },
          meta: result.meta.merge(AlertCapabilities.for_user(Current.user)) }
      end

      def update
        values = params.except(:controller, :action, :format, :id).to_unsafe_h
        unless values.keys == [ "active" ] && [ true, false ].include?(values["active"])
          raise InvalidParameter, "Only a boolean active setting is supported"
        end
        rule = AlertRuleControl.update(user: Current.user, id: AlertParameters.id!(params[:id]), active: values.fetch("active"))
        render json: { data: AlertRuleSerializer.render(rule), meta: AlertCapabilities.for_user(Current.user) }
      end
    end
  end
end
