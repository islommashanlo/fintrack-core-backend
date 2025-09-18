class JwtVerifier
  class Unauthorized < StandardError; end

  def self.verify!(token)
    issuer = ENV.fetch("CLERK_ISSUER", nil)
    jwks_url = ENV.fetch("CLERK_JWKS_URL", nil)
    raise Unauthorized, "Auth not configured" if issuer.blank? || jwks_url.blank?

    jwks = jwks(jwks_url)
    decoded, = JWT.decode(
      token,
      nil,
      true,
      algorithms: ["RS256"],
      iss: issuer,
      verify_iss: true,
      aud: ENV["CLERK_AUDIENCE"],
      verify_aud: ENV["CLERK_AUDIENCE"].present?,
      jwks: jwks
    )
    decoded
  rescue JWT::DecodeError => e
    raise Unauthorized, e.message
  end

  def self.jwks(url)
    cache_key = "jwks:#{url}"
    cached = Rails.cache.read(cache_key)
    return cached if cached
    body = Net::HTTP.get(URI(url))
    data = JSON.parse(body)
    Rails.cache.write(cache_key, data, expires_in: 5.minutes)
    data
  end
end


