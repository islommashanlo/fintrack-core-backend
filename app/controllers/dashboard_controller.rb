# frozen_string_literal: true

class DashboardController < ApplicationController
  allow_unauthenticated_access

  def index
    @as_of = Time.current
    @next_13f_deadline = Form13fDeadline.new(today: @as_of.in_time_zone("America/New_York").to_date).next
    @institutional_flow = InstitutionalFlow.new(as_of: @as_of).top_moves(limit: 8)
    @smart_money_collisions = SmartMoneyCollisions.new(as_of: @as_of).matches(days: 90, window_days: 45, limit: 8)
    signals = InsiderSignals.new(as_of: @as_of)

    @followed_activity = if Current.user
      FollowedActivity.new(user: Current.user, as_of: @as_of).recent(limit: 12)
    else
      []
    end
    @recent_purchases = signals.recent_purchases(days: 7, limit: 12)
    @cluster_buys = signals.cluster_buys(days: 30, min_insiders: 2, limit: 8)
    @top_insiders = signals.top_insiders(days: 90, limit: 8)
  end
end
