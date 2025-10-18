# frozen_string_literal: true

module Authenticate
  extend ActiveSupport::Concern

  class Unauthorized < StandardError; end

  included do
    rescue_from Unauthorized do
      render json: { error: 'Unauthorized' }, status: :unauthorized
    end
  end

  def authenticate_user!
    return if current_user.present?

    token = authorization_token
    payload = verify_jwt(token)
    user = find_user_by_jwt(payload)
    Current.user = user
  end

  def current_user
    @current_user ||= Current.user
  end

  private

  def authorization_token
    header = request.headers['Authorization']
    return nil if header.blank?

    scheme, token = header.split(' ', 2)
    return nil unless scheme == 'Bearer' && token.present?

    token
  end

  def verify_jwt(token)
    return nil if token.blank?

    JwtVerifier.verify!(token)
  end

  def find_user_by_jwt(payload)
    user_id = payload['user_id']
    return nil if user_id.blank?

    User.find_by(id: user_id)
  end
end
