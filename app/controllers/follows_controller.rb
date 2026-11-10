# frozen_string_literal: true

class FollowsController < ApplicationController
  def create
    target = FollowTarget.new(type: follow_params[:target_type], key: follow_params[:target_key]).resolve
    unless target
      redirect_back fallback_location: discover_path, alert: "That filing profile could not be found."
      return
    end

    follow = WatchlistMembership.add(user: Current.user, target:, create_alert_rule: true).follow
    follow.create_alert_rule!(event_type: "new_filing", channel: "email") unless follow.alert_rule
    redirect_back fallback_location: root_path, notice: "Following #{target.label}."
  rescue ActiveRecord::RecordNotUnique
    redirect_back fallback_location: root_path, notice: "You are already following that profile."
  rescue PlanCatalog::Required => e
    redirect_back fallback_location: root_path, alert: "The Free plan allows #{e.limit} watchlist items."
  end

  def destroy
    WatchlistMembership.remove(user: Current.user, id: params[:id])
    redirect_back fallback_location: root_path, notice: "Follow removed."
  end

  private

  def follow_params
    params.require(:follow).permit(:target_type, :target_key).to_h.symbolize_keys
  end
end
