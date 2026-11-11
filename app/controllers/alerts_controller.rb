# frozen_string_literal: true

class AlertsController < ApplicationController
  def index
    @rules = Current.user.alert_rules.retained.includes(:follow, :setting).order(created_at: :asc)
    @deliveries = Current.user.alert_deliveries.includes(:filing, :news_alert_snapshot, alert_rule: :follow)
                                .order(created_at: :desc).limit(30)
    @news_visible_ids = NewsAlertValidity.visible_ids(@deliveries.filter_map(&:news_alert_snapshot_id), as_of: Time.current)
  end
end
