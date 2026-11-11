# frozen_string_literal: true

require "base64"
require "digest"

class EmailUnsubscribe
  class InvalidToken < StandardError; end

  def self.token(user)
    payload = { "user_id" => user.id, "version" => user.notification_preference&.unsubscribe_version || 0,
                "email" => Digest::SHA256.hexdigest(user.email_address) }
    Base64.urlsafe_encode64(verifier.generate(payload, purpose: "email_unsubscribe", expires_in: 1.year), padding: false)
  end

  def self.url(user)
    options = Rails.application.config.action_mailer.default_url_options.to_h.symbolize_keys
    Rails.application.routes.url_helpers.email_unsubscribe_url(**options, token: token(user), protocol: "https")
  end

  def self.resolve(token)
    raise InvalidToken unless token.is_a?(String) && token.bytesize <= 8192
    payload = verifier.verified(Base64.urlsafe_decode64(token), purpose: "email_unsubscribe")
    raise InvalidToken unless payload.is_a?(Hash)
    user = User.find_by(id: payload["user_id"])
    raise InvalidToken unless user && Digest::SHA256.hexdigest(user.email_address) == payload["email"]
    [ user, payload ]
  rescue ArgumentError
    raise InvalidToken
  end

  def self.disable(token)
    user, payload = resolve(token)
    user.with_lock do
      raise InvalidToken unless Digest::SHA256.hexdigest(user.email_address) == payload["email"]
      preference = user.notification_preference
      raise InvalidToken unless preference
      version = payload.fetch("version")
      if preference.unsubscribe_version == version
        preference.update!(email_enabled: false, unsubscribe_version: version + 1)
      elsif preference.email_enabled? || preference.unsubscribe_version != version + 1
        raise InvalidToken
      end
    end
  end

  def self.verifier
    Rails.application.message_verifier("notification_unsubscribe")
  end
  private_class_method :verifier
end
