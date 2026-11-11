# frozen_string_literal: true

class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: :edit
  prepend_before_action :private_response
  rescue_from ApiRateLimiter::Limited, with: :render_rate_limited
  rescue_from ApiRateLimiter::Unavailable, PasswordRecovery::DeliveryUnavailable, with: :render_unavailable

  def new
  end

  def create
    email = params[:email_address]
    unless email.is_a?(String) && email.bytesize <= 254 && email.strip.match?(URI::MailTo::EMAIL_REGEXP)
      return render plain: "Enter a valid email address", status: :bad_request
    end
    PasswordRecovery.request(email:, ip_address: request.remote_ip, target: "html")

    redirect_to new_session_path, notice: "Password reset instructions sent (if user with that email address exists)."
  end

  def edit
  end

  def update
    ApiRateLimiter.check!(scope: "password_reset", identifier: request.remote_ip, limit: 10, window: 15.minutes)
    PasswordRecovery.reset(token: params[:token], password: params[:password], password_confirmation: params[:password_confirmation])
    redirect_to new_session_path, notice: "Password has been reset."
  rescue PasswordRecovery::InvalidToken
    redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
  rescue ActiveRecord::RecordInvalid
    redirect_to edit_password_path(params[:token]), alert: "Enter matching passwords of at least eight characters."
  end

  private
    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
    end

    def private_response
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def render_rate_limited(error)
      response.headers["Retry-After"] = error.retry_after.to_s
      render plain: "Try again later", status: :too_many_requests
    end

    def render_unavailable
      response.headers["Retry-After"] = "60"
      render plain: "Password recovery is temporarily unavailable", status: :service_unavailable
    end
end
