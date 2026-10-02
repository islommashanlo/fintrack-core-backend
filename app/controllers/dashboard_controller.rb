# frozen_string_literal: true

class DashboardController < ApplicationController
  allow_unauthenticated_access

  def index
    @as_of = Time.current
    @next_13f_deadline = Form13fDeadline.new(today: @as_of.to_date).next
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
