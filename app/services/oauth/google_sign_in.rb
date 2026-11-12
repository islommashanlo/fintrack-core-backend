# frozen_string_literal: true

module Oauth
  class GoogleSignIn
    LIFETIME = 5.minutes
    Result = Data.define(:state, :nonce, :expires_at, :intent)

    def self.enabled?
      ENV["OAUTH_GOOGLE_SIGN_IN"] == "on" && GoogleLinking.client_id.present?
    end

    def self.require_enabled!
      raise GoogleLinking::Unavailable unless enabled?
    end

    def self.start(previous_intent: nil)
      require_enabled!
      state, nonce = SecureRandom.urlsafe_base64(32), SecureRandom.urlsafe_base64(32)
      expires_at = LIFETIME.from_now
      intent = { "state_digest" => digest(state), "nonce_digest" => digest(nonce), "expires_at" => expires_at.to_i }
      stored = FilingsIntel.redis.call("SET", redis_key(state), digest(nonce), "NX", "EX", LIFETIME.to_i)
      raise GoogleLinking::Unavailable unless stored == "OK"

      if previous_intent.is_a?(Hash) && previous_intent["state_digest"].is_a?(String) && previous_intent["state_digest"].match?(/\A[0-9a-f]{64}\z/)
        FilingsIntel.redis.call("DEL", "oauth:google_sign_in:intent:#{previous_intent.fetch("state_digest")}")
      end
      Result.new(state:, nonce:, expires_at:, intent:)
    rescue RedisClient::Error
      raise GoogleLinking::Unavailable
    end

    def self.complete(intent:, state:, id_token:)
      require_enabled!
      raise ArgumentError, "Session creation block is required" unless block_given?
      raise GoogleLinking::Invalid unless state.is_a?(String) && state.match?(/\A[A-Za-z0-9_-]{43}\z/) && intent.is_a?(Hash) &&
        intent["expires_at"].is_a?(Integer) && intent["expires_at"] > Time.current.to_i && intent["state_digest"] == digest(state)

      expected_client = GoogleLinking.client_id
      claims = GoogleTokenVerifier.verify(id_token, client_id: expected_client)
      raise GoogleLinking::Invalid unless intent["nonce_digest"].is_a?(String) &&
        ActiveSupport::SecurityUtils.secure_compare(intent["nonce_digest"], digest(claims.fetch(:nonce)))

      identity = OauthIdentity.find_by(provider: "google", subject: claims.fetch(:subject))
      raise GoogleLinking::Invalid unless identity

      user = User.find_by(id: identity.user_id)
      raise GoogleLinking::Invalid unless user

      user.with_lock do
        require_enabled!
        raise GoogleLinking::Unavailable unless GoogleLinking.client_id == expected_client
        raise GoogleLinking::Invalid unless intent["expires_at"] > Time.current.to_i &&
          user.oauth_identities.exists?(id: identity.id, provider: "google", subject: claims.fetch(:subject))

        # Consume before session creation: a later failure requires a fresh start.
        # Missing Redis state (including after cache loss) always fails closed.
        stored = FilingsIntel.redis.call("GETDEL", redis_key(state))
        raise GoogleLinking::Invalid unless stored.is_a?(String) &&
          ActiveSupport::SecurityUtils.secure_compare(stored, intent.fetch("nonce_digest"))

        yield user
        user
      end
    rescue RedisClient::Error
      raise GoogleLinking::Unavailable
    end

    def self.redis_key(state)
      "oauth:google_sign_in:intent:#{digest(state)}"
    end
    private_class_method :redis_key

    def self.digest(value)
      Digest::SHA256.hexdigest(value)
    end
    private_class_method :digest
  end
end
