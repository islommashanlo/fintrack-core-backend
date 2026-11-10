# frozen_string_literal: true

module Api
  module V1
    module SessionManagement
      private

      def rotate_api_session(user, revoke_all: false)
        Session.transaction do
          revoke_all ? user.sessions.destroy_all : Current.session&.destroy!
          Current.session = user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip)
        end
        reset_session
        cookies.signed[:session_id] = {
          value: Current.session.id, expires: Session::LIFETIME.from_now, httponly: true,
          same_site: :lax, secure: request.ssl? || Rails.env.production?, path: "/"
        }
      end

      def clear_api_session
        Current.session&.destroy!
        Current.session = nil
        cookies.delete(:session_id, path: "/")
        reset_session
      end

      def render_session(user, status: :ok)
        render json: { data: { user: UserSerializer.render(user), csrf_token: form_authenticity_token } }, status:
      end
    end
  end
end
