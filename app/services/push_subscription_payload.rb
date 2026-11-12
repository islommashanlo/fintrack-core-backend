# frozen_string_literal: true

require "base64"
require "openssl"
require "uri"

class PushSubscriptionPayload
  Value = Data.define(:payload, :canonical_endpoint, :endpoint_origin, :expires_at)

  def self.parse(values, now: Time.current)
    invalid! unless values.is_a?(Hash) && values.keys.sort == %w[consent subscription] && values["consent"] == true
    data = values["subscription"]
    invalid! unless data.is_a?(Hash) && (data.keys - %w[endpoint expirationTime keys]).empty? && data.key?("endpoint") && data.key?("keys")
    endpoint = data["endpoint"]
    invalid! unless endpoint.is_a?(String) && endpoint.ascii_only? && endpoint.bytesize.between?(1, 2048) && !endpoint.match?(/[[:space:][:cntrl:]]/)
    uri = URI.parse(endpoint)
    invalid! unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil? && uri.port == 443
    # No DNS lookup: registration validates structure, not provider ownership.
    host = uri.host.downcase
    invalid! unless host.bytesize <= 253 && host.match?(/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/) && !host.end_with?(".localhost", ".local", ".internal")
    keys = data["keys"]
    invalid! unless keys.is_a?(Hash) && keys.keys.sort == %w[auth p256dh]
    public_key = decode(keys["p256dh"], 65)
    invalid! unless public_key.getbyte(0) == 4
    point = OpenSSL::PKey::EC::Point.new(OpenSSL::PKey::EC::Group.new("prime256v1"), OpenSSL::BN.new(public_key, 2))
    invalid! unless point.on_curve? && !point.infinity?
    decode(keys["auth"], 16)
    expiration = data["expirationTime"]
    unless expiration.nil?
      invalid! unless expiration.is_a?(Integer) && expiration.between?(1, 253_402_300_799_999)
      expires_at = Time.at(Rational(expiration, 1000)).utc
      invalid! unless expires_at > now
    end
    origin = "https://#{host}"
    Value.new(payload: { "endpoint" => endpoint, "keys" => keys.dup, "expirationTime" => expiration },
      canonical_endpoint: "#{origin}#{uri.request_uri}", endpoint_origin: origin, expires_at:)
  rescue URI::InvalidURIError, OpenSSL::PKey::EC::Point::Error, OpenSSL::PKey::ECError, OpenSSL::BNError, ArgumentError
    invalid!
  end

  def self.decode(value, bytes)
    invalid! unless value.is_a?(String) && value.bytesize <= 100 && value.match?(/\A[A-Za-z0-9_-]+\z/)
    decoded = Base64.urlsafe_decode64(value)
    invalid! unless decoded.bytesize == bytes && Base64.urlsafe_encode64(decoded, padding: false) == value
    decoded
  end
  private_class_method :decode

  def self.invalid!
    raise Api::V1::InvalidParameter, "Invalid push subscription"
  end
end
