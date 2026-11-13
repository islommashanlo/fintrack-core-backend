# frozen_string_literal: true

module Api
  module V1
    class OauthLinkingController < ProtectedController
      include GoogleCallbackParameters
      prepend_before_action { response.headers["Referrer-Policy"] = "no-referrer" }
      rescue_from Oauth::GoogleLinking::Unavailable do
        render json: { error: { code: "OAUTH_UNAVAILABLE", message: "External account linking is unavailable" } }, status: :service_unavailable
      end
      rescue_from Oauth::GoogleLinking::Invalid do
        render json: { error: { code: "OAUTH_INVALID", message: "Start account linking again" } }, status: :unauthorized
      end
      rescue_from Oauth::GoogleLinking::Conflict do
        render json: { error: { code: "OAUTH_CONFLICT", message: "This external account link is unavailable" } }, status: :conflict
      end
      rescue_from OauthLinkIntents::ReauthenticationRequired do
        render json: { error: { code: "REAUTHENTICATION_REQUIRED", message: "Current password is incorrect" } }, status: :unauthorized
      end
      rescue_from OauthLinkIntents::Invalid do
        render json: { error: { code: "OAUTH_INVALID", message: "Start account linking again" } }, status: :unauthorized
      end

      def start
        values = read_parameters(allowed: %w[current_password])
        require_parameters!(values, "current_password")
        result = Oauth::GoogleLinking.start(user: Current.user, session: Current.session, current_password: values.fetch("current_password"))
        render json: { data: { state: result.state, nonce: result.nonce, expires_at: result.expires_at,
          client_id: Oauth::GoogleLinking.client_id } }
      end

      def authorize
        values = read_parameters(allowed: %w[current_password])
        require_parameters!(values, "current_password")
        result = Oauth::GoogleCodeLinking.start(user: Current.user, session: Current.session, **values.symbolize_keys)
        session[:oauth_google_link_code] = result.intent
        render json: { data: { authorization_url: result.authorization_url, expires_at: result.expires_at } }
      end

      def callback
        ApiRateLimiter.check!(scope: "oauth_code_callback", identifier: Current.user.id, limit: 10, window: 3.minutes)
        Oauth::GoogleCodeLinking.complete(user: Current.user, session: Current.session, intent: session[:oauth_google_link_code],
          **google_callback_parameters) { rotate_api_session(Current.user, revoke_all: true) }
        render_session(Current.user)
      end

      def complete
        values = read_parameters(allowed: %w[state id_token])
        require_parameters!(values, "state", "id_token")
        ApiRateLimiter.check!(scope: "oauth_complete", identifier: Current.user.id, limit: 10, window: 3.minutes)
        Oauth::GoogleLinking.complete(user: Current.user, session: Current.session, **values.symbolize_keys) do
          rotate_api_session(Current.user, revoke_all: true)
        end
        render_session(Current.user)
      end
    end
  end
end
