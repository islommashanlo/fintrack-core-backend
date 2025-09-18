module Authenticate
  extend ActiveSupport::Concern

  class Unauthorized < StandardError; end

  included do
    rescue_from Unauthorized do
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def authenticate_user!
    token = authorization_token
    payload = verify_jwt(token)
    user = find_or_sync_user(payload)
    Current.user = user
  end

  private

  def authorization_token
    header = request.headers["Authorization"]
    raise Unauthorized, "Missing Authorization header" if header.blank?
    scheme, token = header.split(" ", 2)
    raise Unauthorized, "Invalid auth scheme" unless scheme == "Bearer" && token.present?
    token
  end

  def verify_jwt(token)
    JwtVerifier.verify!(token)
  end

  def find_or_sync_user(payload)
    clerk_id = payload["sub"]
    email = payload.dig("email") || payload.dig("claims", "email")
    user = User.find_by(clerk_id: clerk_id)
    return user if user
    User.create!(clerk_id: clerk_id, email: email || "unknown@example.com")
  end
end


