# frozen_string_literal: true

class FollowsController < ApplicationController
  def create
    target = FollowTarget.new(type: follow_params[:target_type], key: follow_params[:target_key]).resolve
    unless target
      redirect_back fallback_location: discover_path, alert: "That filing profile could not be found."
      return
    end

    Current.user.follows.create_or_find_by!(target_type: target.type, target_key: target.key)
    redirect_back fallback_location: root_path, notice: "Following #{target.label}."
  rescue ActiveRecord::RecordNotUnique
    redirect_back fallback_location: root_path, notice: "You are already following that profile."
  end

  def destroy
    Current.user.follows.find(params[:id]).destroy!
    redirect_back fallback_location: root_path, notice: "Follow removed."
  end

  private

  def follow_params
    params.require(:follow).permit(:target_type, :target_key).to_h.symbolize_keys
  end
end
