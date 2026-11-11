# frozen_string_literal: true

require "active_support/message_encryptor"

class PasswordRecovery
  class InvalidToken < StandardError; end
  class DeliveryUnavailable < StandardError; end

  def self.request(email:, ip_address:, target: "frontend")
    ApiRateLimiter.check!(scope: "password_forgot", identifier: ip_address, limit: 10, window: 1.hour)
    normalized = email.strip.downcase
    ApiRateLimiter.check!(scope: "password_forgot_email", identifier: normalized, limit: 3, window: 15.minutes)
    user = User.find_by(email_address: normalized)
    payload = encryptor.encrypt_and_sign(
      { "user_id" => user&.id, "token" => user&.password_reset_token, "target" => target },
      purpose: "password_recovery", expires_in: 15.minutes
    )
    # The same job is queued for known and unknown addresses; no token is returned.
    raise DeliveryUnavailable unless SendPasswordResetJob.perform_later(payload)
  rescue ActiveJob::EnqueueError, RedisClient::Error
    raise DeliveryUnavailable
  end

  def self.payload(encrypted)
    encryptor.decrypt_and_verify(encrypted, purpose: "password_recovery")
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def self.reset(token:, password:, password_confirmation:)
    raise InvalidToken unless token.is_a?(String) && token.present? && token.bytesize <= 2048

    user = User.find_by_password_reset_token(token)
    raise InvalidToken unless user

    user.with_lock do
      # Revalidate after the lock: concurrent consumers cannot reuse the token.
      raise InvalidToken unless User.find_by_password_reset_token(token)&.id == user.id

      unless password.is_a?(String) && password.present? && password_confirmation.is_a?(String) && password_confirmation.present?
        user.errors.add(:password, "and confirmation are required")
        raise ActiveRecord::RecordInvalid, user
      end
      user.update!(password:, password_confirmation:)
      user.sessions.delete_all
    end
    user
  end

  def self.encryptor
    key = Rails.application.key_generator.generate_key("password-recovery-v1", 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JSON, url_safe: true)
  end
  private_class_method :encryptor
end
