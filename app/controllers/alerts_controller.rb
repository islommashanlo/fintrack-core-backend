# frozen_string_literal: true

class AlertsController < ApplicationController
  def index
    @rules = Current.user.alert_rules.retained.includes(:follow, :setting).order(created_at: :asc)
    @deliveries = Current.user.alert_deliveries.includes(:filing, alert_rule: :follow)
                                .order(created_at: :desc).limit(30)
  end
end
