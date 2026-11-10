# frozen_string_literal: true

class UsersController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  before_action :limit_signup, only: :create
  rescue_from ApiRateLimiter::Limited, with: -> { render plain: "Try again later", status: :too_many_requests }
  rescue_from ApiRateLimiter::Unavailable, with: -> { render plain: "Sign up is temporarily unavailable", status: :service_unavailable }

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    if @user.save
      start_new_session_for(@user)
      redirect_to root_path, notice: "Welcome to FilingsIntel."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def limit_signup
    ApiRateLimiter.check!(scope: "signup", identifier: request.remote_ip, limit: 10, window: 1.hour)
  end

  def user_params
    params.require(:user).permit(:email_address, :password, :password_confirmation)
  end
end
