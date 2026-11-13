# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_session

    def connect
      reject_unauthorized_connection unless InAppInboxRealtime.enabled? && trusted_origin?
      ApiRateLimiter.check!(scope: "in_app_socket_ip", identifier: request.remote_ip, limit: 30, window: 1.minute)
      self.current_session = Session.active.find_by(id: cookies.signed[:session_id])
      reject_unauthorized_connection unless current_session
      ApiRateLimiter.check!(scope: "in_app_socket_user", identifier: current_session.user_id, limit: 30, window: 1.minute)
    rescue ApiRateLimiter::Limited, ApiRateLimiter::Unavailable
      reject_unauthorized_connection
    end

    def session_active?
      InAppInboxRealtime.enabled? && current_session &&
        Session.active.where(id: current_session.id, user_id: current_session.user_id).exists?
    end

    private

    def trusted_origin?
      request.origin.present? && [ request.base_url, Middleware::ApiCors.origin ].compact.include?(request.origin)
    end
  end
end
