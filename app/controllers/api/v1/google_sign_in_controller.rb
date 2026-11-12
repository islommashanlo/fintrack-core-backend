# frozen_string_literal: true

module Api
  module V1
    class GoogleSignInController < BaseController
      prepend_before_action :private_response!
      before_action :require_signed_out
      before_action :limit_sign_in

      rescue_from Oauth::GoogleLinking::Unavailable do
        render json: { error: { code: "OAUTH_UNAVAILABLE", message: "External sign-in is unavailable" } }, status: :service_unavailable
      end
      rescue_from Oauth::GoogleLinking::Invalid do
        render json: { error: { code: "OAUTH_INVALID", message: "Unable to sign in; start again or use your password" } }, status: :unauthorized
      end

      def start
        read_parameters(allowed: [])
        result = Oauth::GoogleSignIn.start(previous_intent: session[:oauth_google_sign_in])
        session[:oauth_google_sign_in] = result.intent
        render json: { data: { state: result.state, nonce: result.nonce, expires_at: result.expires_at,
          client_id: Oauth::GoogleLinking.client_id } }
      end

      def complete
        values = read_parameters(allowed: %w[state id_token])
        require_parameters!(values, "state", "id_token")
        user = Oauth::GoogleSignIn.complete(intent: session[:oauth_google_sign_in], **values.symbolize_keys) do |account|
          rotate_api_session(account)
        end
        render_session(user)
      end

      private

      def require_signed_out
        return unless Current.session

        render json: { error: { code: "ALREADY_SIGNED_IN", message: "Sign out before starting another sign-in" } }, status: :conflict
      end

      def limit_sign_in
        ApiRateLimiter.check!(scope: "google_sign_in_#{action_name}", identifier: request.remote_ip, limit: 10, window: 3.minutes)
      end
    end
  end
end
