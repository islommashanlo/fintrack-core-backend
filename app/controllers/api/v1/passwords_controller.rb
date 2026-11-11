# frozen_string_literal: true

module Api
  module V1
    class PasswordsController < BaseController
      prepend_before_action :private_response!

      def forgot
        values = read_parameters(allowed: %w[email])
        require_parameters!(values, "email")
        unless values.fetch("email").bytesize <= 254 && values.fetch("email").strip.match?(URI::MailTo::EMAIL_REGEXP)
          raise InvalidParameter, "Invalid email parameter"
        end
        PasswordRecovery.request(email: values.fetch("email"), ip_address: request.remote_ip)
        render json: { data: { message: "If an account matches that email, password reset instructions will be sent." } }, status: :accepted
      rescue PasswordRecovery::DeliveryUnavailable
        response.headers["Retry-After"] = "60"
        render json: { error: { code: "TEMPORARILY_UNAVAILABLE", message: "Password recovery is temporarily unavailable" } }, status: :service_unavailable
      end

      def reset
        ApiRateLimiter.check!(scope: "password_reset", identifier: request.remote_ip, limit: 10, window: 15.minutes)
        values = read_parameters(allowed: %w[token password password_confirmation])
        require_parameters!(values, "token", "password", "password_confirmation")
        raise InvalidParameter, "Invalid token parameter" if values.fetch("token").bytesize > 2048

        PasswordRecovery.reset(**values.symbolize_keys)
        clear_api_session
        render json: { data: { message: "Password reset. Sign in with your new password.", csrf_token: form_authenticity_token } }
      rescue PasswordRecovery::InvalidToken
        render json: { error: { code: "INVALID_RESET_TOKEN", message: "Password reset link is invalid or has expired" } }, status: :bad_request
      end
    end
  end
end
