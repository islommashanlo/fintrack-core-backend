# frozen_string_literal: true

class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  before_action :limit_sign_in, only: :create
  rescue_from ApiRateLimiter::Limited, with: -> { redirect_to new_session_url, alert: "Try again later." }
  rescue_from ApiRateLimiter::Unavailable, with: -> { render plain: "Sign in is temporarily unavailable", status: :service_unavailable }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      user.with_lock do
        unless user.email_address == params[:email_address].strip.downcase && user.authenticate(params[:password])
          return redirect_to new_session_path, alert: "Try another email address or password."
        end
        start_new_session_for user
      end
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path
  end

  private

  def limit_sign_in
    ApiRateLimiter.check!(scope: "login", identifier: request.remote_ip, limit: 10, window: 3.minutes)
  end
end
