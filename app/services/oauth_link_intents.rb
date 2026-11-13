# frozen_string_literal: true

class OauthLinkIntents
  LIFETIME = 5.minutes
  Result = Data.define(:state, :nonce, :expires_at)
  class Invalid < StandardError; end
  class Unavailable < StandardError; end
  class ReauthenticationRequired < StandardError; end

  def self.issue(user:, session:, current_password:, flow: "id_token")
    raise Invalid unless OauthLinkIntent::FLOWS.include?(flow)
    ApiRateLimiter.check!(scope: "oauth_link", identifier: user.id, limit: 10, window: 3.minutes)
    user.with_lock do
      raise ReauthenticationRequired unless current_password.is_a?(String) && user.authenticate(current_password)

      active_session = user.sessions.active.lock.find_by(id: session.id)
      raise Invalid unless active_session

      state, nonce = SecureRandom.urlsafe_base64(32), SecureRandom.urlsafe_base64(32)
      expires_at = LIFETIME.from_now
      record = OauthLinkIntent.find_or_initialize_by(session: active_session)
      previous = record.state_digest if record.persisted? && record.flow == "code"
      record.update!(state_digest: digest(state), nonce_digest: digest(nonce), expires_at:, consumed_at: nil, flow:)
      if flow == "code"
        stored = FilingsIntel.redis.call("SET", code_key(record.state_digest), record.nonce_digest, "NX", "EX", LIFETIME.to_i)
        raise Unavailable unless stored == "OK"
      end
      FilingsIntel.redis.call("DEL", code_key(previous)) if previous
      Result.new(state:, nonce:, expires_at:)
    end
  rescue RedisClient::Error
    raise Unavailable
  end

  # Call only after provider verification. This method does not verify an ID token
  # or establish an identity; it enforces the local, one-use linking intent.
  def self.consume(user:, session:, state:, nonce:, flow: "id_token")
    raise Invalid unless [ state, nonce ].all? { |value| value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]{43}\z/) }

    user.with_lock do
      record = active_intent(user:, session:, state:, flow:)
      raise Invalid unless ActiveSupport::SecurityUtils.secure_compare(record.nonce_digest, digest(nonce))

      record.update!(consumed_at: Time.current)
      record
    end
  end

  def self.claim_code(user:, session:, state:)
    user.with_lock do
      record = active_intent(user:, session:, state:, flow: "code")
      stored = FilingsIntel.redis.call("GETDEL", code_key(record.state_digest))
      raise Invalid unless stored.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(stored, record.nonce_digest)
    end
  rescue RedisClient::Error
    raise Unavailable
  end

  def self.active_intent(user:, session:, state:, flow:)
    raise Invalid unless state.is_a?(String) && state.match?(/\A[A-Za-z0-9_-]{43}\z/)
    active_session = user.sessions.active.lock.find_by(id: session.id)
    raise Invalid unless active_session
    record = OauthLinkIntent.lock.find_by(session: active_session, state_digest: digest(state), flow:)
    raise Invalid unless record && record.consumed_at.nil? && record.expires_at > Time.current
    record
  end
  private_class_method :active_intent

  def self.code_key(state_digest)
    "oauth:google_link_code:intent:#{state_digest}"
  end
  private_class_method :code_key

  def self.digest(value)
    Digest::SHA256.hexdigest(value)
  end
  private_class_method :digest
end
