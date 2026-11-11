# frozen_string_literal: true

require "openssl"

module Billing
  class StripeSignature
    class Invalid < StandardError; end
    TOLERANCE = 300

    def self.verify!(body:, header:, secret:, now: Time.current)
      raise Invalid unless header.is_a?(String) && header.bytesize <= 8192 && secret.present?

      entries = header.split(",").map { |part| part.strip.split("=", 2) }
      timestamps = entries.select { |key, _| key == "t" }.map(&:last)
      raise Invalid unless timestamps.size == 1 && timestamps.first&.match?(/\A\d{1,12}\z/)

      timestamp = timestamps.first
      signatures = entries.select { |key, _| key == "v1" }.map(&:last).compact
      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, timestamp.b + "." + body.b)
      matched = signatures.any? do |signature|
        signature.match?(/\A[0-9a-f]{64}\z/) && ActiveSupport::SecurityUtils.fixed_length_secure_compare(expected, signature)
      end
      raise Invalid unless matched && (now.to_i - timestamp.to_i).abs <= TOLERANCE
    end
  end
end
