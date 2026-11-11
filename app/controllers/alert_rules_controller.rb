# frozen_string_literal: true

class AlertRulesController < ApplicationController
  def update
    rule = AlertRuleControl.update(user: Current.user, id: params[:id], active: ActiveModel::Type::Boolean.new.cast(alert_rule_params[:active]))
    redirect_to alerts_path, notice: rule.active? ? "Alert resumed." : "Alert paused."
  rescue PlanCatalog::Required, AlertRuleControl::InvalidConfiguration => e
    redirect_to alerts_path, alert: e.message
  end

  private

  def alert_rule_params
    params.require(:alert_rule).permit(:active)
  end
end
