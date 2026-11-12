# frozen_string_literal: true

module PushSubscriptionFixtures
  def push_registration(endpoint: "https://push.example.invalid/messages/private-capability-token-0001", expiration: nil)
    @push_public_key ||= Base64.urlsafe_encode64(OpenSSL::PKey::EC.generate("prime256v1").public_key.to_octet_string(:uncompressed), padding: false)
    { "consent" => true, "subscription" => { "endpoint" => endpoint, "expirationTime" => expiration,
      "keys" => { "p256dh" => @push_public_key, "auth" => Base64.urlsafe_encode64("0123456789abcdef", padding: false) } } }
  end
end

RSpec.configure { |config| config.include PushSubscriptionFixtures }
