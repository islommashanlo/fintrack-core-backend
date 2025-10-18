# frozen_string_literal: true

class JwtVerifier
  class Unauthorized < StandardError; end

  def self.verify!(token)
    secret = ENV.fetch('DEVISE_JWT_SECRET_KEY', 'your-super-secret-jwt-key-change-this-in-production')

    decoded, = JWT.decode(
      token,
      secret,
      true,
      algorithm: 'HS256'
    )
    decoded
  rescue JWT::DecodeError => e
    raise Unauthorized, e.message
  end
end
