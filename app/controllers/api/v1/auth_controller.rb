# frozen_string_literal: true

module Api
  module V1
    class AuthController < BaseController
      prepend_before_action :private_response!
      before_action :limit_authentication, only: %i[signup login]
      before_action :require_authentication, only: :logout

      def csrf
        render json: { data: { csrf_token: form_authenticity_token } }
      end

      def signup
        values = read_parameters(allowed: %w[email password password_confirmation])
        require_parameters!(values, "email", "password")
        user = User.create!(email_address: values["email"], password: values["password"],
                            password_confirmation: values["password_confirmation"])
        rotate_api_session(user)
        render_session(user, status: :created)
      rescue ActiveRecord::RecordNotUnique
        render json: { error: { code: "VALIDATION_FAILED", message: "Email has already been taken" } }, status: :unprocessable_entity
      end

      def login
        values = read_parameters(allowed: %w[email password])
        require_parameters!(values, "email", "password")
        user = User.authenticate_by(email_address: values["email"], password: values["password"])
        unless user
          render json: { error: { code: "INVALID_CREDENTIALS", message: "Invalid email or password" } }, status: :unauthorized
          return
        end
        user.with_lock do
          unless user.email_address == values.fetch("email").strip.downcase && user.authenticate(values.fetch("password"))
            return render json: { error: { code: "INVALID_CREDENTIALS", message: "Invalid email or password" } }, status: :unauthorized
          end
          rotate_api_session(user)
        end
        render_session(user)
      end

      def logout
        clear_api_session
        head :no_content
      end

      private

      def limit_authentication
        ApiRateLimiter.check!(scope: action_name, identifier: request.remote_ip, limit: 10,
                              window: action_name == "signup" ? 1.hour : 3.minutes)
      end
    end
  end
end
