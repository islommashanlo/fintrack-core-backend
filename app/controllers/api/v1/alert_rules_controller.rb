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
        id = AlertParameters.id!(params[:id])
        existing = Current.user.alert_rules.retained.find(id)
        values = AlertRuleParameters.normalize(params.except(:controller, :action, :format, :id).to_unsafe_h, trigger: existing.event_type)
        rule = AlertRuleControl.update(user: Current.user, id:, attributes: values)
        render json: { data: AlertRuleSerializer.render(rule), meta: AlertCapabilities.for_user(Current.user) }
      end

      def create
        values = AlertRuleParameters.normalize(params.except(:controller, :action, :format).to_unsafe_h, create: true)
        result = AlertRuleControl.create(user: Current.user, follow_id: values.delete(:follow_id), attributes: values)
        render json: { data: AlertRuleSerializer.render(result.rule), meta: AlertCapabilities.for_user(Current.user) }, status: result.created ? :created : :ok
      end

      def destroy
        read_parameters(allowed: [], path_keys: [ :id ])
        AlertRuleControl.archive(user: Current.user, id: AlertParameters.id!(params[:id]))
        head :no_content
      end
    end
  end
end
