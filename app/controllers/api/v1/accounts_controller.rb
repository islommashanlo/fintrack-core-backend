# frozen_string_literal: true

module Api
  module V1
    class AccountsController < ProtectedController
      def show
        read_parameters(allowed: [])
        render json: { data: UserSerializer.render(Current.user) }
      end

      def update
        values = read_parameters(allowed: %w[email password password_confirmation current_password])
        require_parameters!(values, "current_password")
        unless values["email"] || values["password"]
          raise InvalidParameter, "An email or password change is required"
        end
        user = Current.user
        user.with_lock do
          return render_reauthentication unless user.authenticate(values["current_password"])

          attributes = values.slice("password", "password_confirmation")
          attributes["email_address"] = values["email"] if values["email"]
          user.update!(attributes)
          rotate_api_session(user, revoke_all: true)
        end
        render_session(user)
      rescue ActiveRecord::RecordNotUnique
        render json: { error: { code: "VALIDATION_FAILED", message: "Email has already been taken" } }, status: :unprocessable_entity
      end

      def destroy
        values = read_parameters(allowed: %w[current_password])
        require_parameters!(values, "current_password")
        user = Current.user
        user.with_lock do
          return render_reauthentication unless user.authenticate(values["current_password"])

          AccountNotificationCleanup.call(user)
          user.destroy!
        end
        clear_api_session
        head :no_content
      end

      private

      def render_reauthentication
        render json: { error: { code: "REAUTHENTICATION_REQUIRED", message: "Current password is incorrect" } }, status: :unauthorized
      end
    end
  end
end
