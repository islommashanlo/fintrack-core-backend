# frozen_string_literal: true

module Api
  module V1
    class OauthIdentitiesController < ProtectedController
      def index
        read_parameters(allowed: [])
        records = Current.user.oauth_identities.order(:id).pluck(:id, :provider, :created_at)
        render json: { data: records.map { |id, provider, created_at| { id:, provider:, linked_at: created_at } },
          meta: { linking_enabled: Oauth::GoogleLinking.enabled?, sign_in_enabled: Oauth::GoogleSignIn.enabled?, unlinking_enabled: true } }
      end

      def destroy
        values = read_parameters(allowed: %w[current_password], path_keys: [ :id ])
        require_parameters!(values, "current_password")
        id = AlertParameters.id!(params[:id])
        user = Current.user
        ApiRateLimiter.check!(scope: "oauth_unlink", identifier: user.id, limit: 10, window: 3.minutes)
        user.with_lock do
          unless user.authenticate(values.fetch("current_password"))
            return render json: { error: { code: "REAUTHENTICATION_REQUIRED", message: "Current password is incorrect" } }, status: :unauthorized
          end
          user.oauth_identities.find(id).destroy!
          rotate_api_session(user, revoke_all: true)
        end
        render_session(user)
      end
    end
  end
end
