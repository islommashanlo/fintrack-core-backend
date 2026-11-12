# frozen_string_literal: true

class OauthLinkIntents
  LIFETIME = 5.minutes
  Result = Data.define(:state, :nonce, :expires_at)
  class Invalid < StandardError; end
  class ReauthenticationRequired < StandardError; end

  def self.issue(user:, session:, current_password:)
    ApiRateLimiter.check!(scope: "oauth_link", identifier: user.id, limit: 10, window: 3.minutes)
    user.with_lock do
      raise ReauthenticationRequired unless current_password.is_a?(String) && user.authenticate(current_password)

      active_session = user.sessions.active.lock.find_by(id: session.id)
      raise Invalid unless active_session

      state, nonce = SecureRandom.urlsafe_base64(32), SecureRandom.urlsafe_base64(32)
      expires_at = LIFETIME.from_now
      record = OauthLinkIntent.find_or_initialize_by(session: active_session)
      record.update!(state_digest: digest(state), nonce_digest: digest(nonce), expires_at:, consumed_at: nil)
      Result.new(state:, nonce:, expires_at:)
    end
  end

  # Call only after provider verification. This method does not verify an ID token
  # or establish an identity; it enforces the local, one-use linking intent.
  def self.consume(user:, session:, state:, nonce:)
    raise Invalid unless [ state, nonce ].all? { |value| value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]{43}\z/) }

    user.with_lock do
      active_session = user.sessions.active.lock.find_by(id: session.id)
      raise Invalid unless active_session

      record = OauthLinkIntent.lock.find_by(session: active_session, state_digest: digest(state))
      raise Invalid unless record && record.consumed_at.nil? && record.expires_at > Time.current &&
        ActiveSupport::SecurityUtils.secure_compare(record.nonce_digest, digest(nonce))

      record.update!(consumed_at: Time.current)
      record
    end
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(value)
  end
  private_class_method :digest
end
