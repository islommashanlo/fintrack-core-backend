# frozen_string_literal: true

require "active_support/message_encryptor"

class PushSubscriptionSecrets
  def self.digest(endpoint)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key("push-endpoint-digest-v1", 32), endpoint)
  end

  def self.encrypt(payload, user_id:, session_id:, digest:)
    encryptor.encrypt_and_sign(payload, purpose: purpose(user_id, session_id, digest))
  end

  def self.decrypt(record)
    encryptor.decrypt_and_verify(record.encrypted_payload, purpose: purpose(record.user_id, record.session_id, record.endpoint_digest)) ||
      raise(ActiveSupport::MessageEncryptor::InvalidMessage)
  end

  def self.purpose(user_id, session_id, digest)
    "push-subscription-v1:#{user_id}:#{session_id}:#{digest}"
  end
  private_class_method :purpose

  def self.encryptor
    key = Rails.application.key_generator.generate_key("push-subscription-payload-v1", 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JSON, url_safe: true)
  end
  private_class_method :encryptor
end
