# frozen_string_literal: true

class AlertRulesController < ApplicationController
  def update
    rule = Current.user.alert_rules.find(params[:id])
    rule.update!(active: ActiveModel::Type::Boolean.new.cast(alert_rule_params[:active]))
    redirect_to alerts_path, notice: rule.active? ? "Alert resumed." : "Alert paused."
  end

  private

  def alert_rule_params
    params.require(:alert_rule).permit(:active)
  end
end
