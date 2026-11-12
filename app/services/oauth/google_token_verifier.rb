# frozen_string_literal: true

require "googleauth/id_tokens"
require "timeout"

module Oauth
  class GoogleTokenVerifier
    def self.verify(token, client_id:)
      raise GoogleLinking::Invalid unless token.is_a?(String) && token.bytesize.between?(1, 16_384)

      payload = Timeout.timeout(5) { Google::Auth::IDTokens.verify_oidc(token, aud: client_id) }
      now = Time.current.to_i
      valid = payload["aud"] == client_id && Google::Auth::IDTokens::OIDC_ISSUERS.include?(payload["iss"]) &&
        (!payload.key?("azp") || payload["azp"] == client_id) &&
        payload["exp"].is_a?(Integer) && payload["exp"] > now &&
        payload["iat"].is_a?(Integer) && payload["iat"] <= now + 60 && payload["iat"] < payload["exp"] &&
        payload["sub"].is_a?(String) && payload["sub"].match?(/\A[[:graph:]]{1,255}\z/) &&
        payload["nonce"].is_a?(String) && payload["nonce"].match?(/\A[A-Za-z0-9_-]{43}\z/)
      raise GoogleLinking::Invalid unless valid

      { subject: payload.fetch("sub"), nonce: payload.fetch("nonce") }
    rescue Google::Auth::IDTokens::VerificationError
      raise GoogleLinking::Invalid
    rescue Google::Auth::IDTokens::KeySourceError, Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError
      raise GoogleLinking::Unavailable
    end
  end
end
