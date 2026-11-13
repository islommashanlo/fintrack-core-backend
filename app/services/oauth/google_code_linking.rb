# frozen_string_literal: true

module Oauth
  class GoogleCodeLinking
    Result = Data.define(:authorization_url, :expires_at, :intent)

    def self.configuration
      GoogleCodeFlow.configuration(flow: "link")
    end

    def self.start(user:, session:, current_password:)
      config = configuration
      challenge = GoogleLinking.start(user:, session:, current_password:, flow: "code")
      verifier = SecureRandom.urlsafe_base64(32)
      intent = { "state_digest" => Digest::SHA256.hexdigest(challenge.state), "user_id" => user.id, "session_id" => session.id,
        "code_verifier" => verifier, "configuration_digest" => GoogleCodeFlow.fingerprint(config) }
      Result.new(authorization_url: GoogleCodeFlow.url(configuration: config, state: challenge.state, nonce: challenge.nonce, verifier:),
        expires_at: challenge.expires_at, intent:)
    end

    def self.complete(user:, session:, intent:, state:, code: nil, error: nil)
      config = configuration
      fingerprint = GoogleCodeFlow.fingerprint(config)
      raise GoogleLinking::Invalid unless state.is_a?(String) && state.match?(/\A[A-Za-z0-9_-]{43}\z/) &&
        intent.is_a?(Hash) && intent["user_id"] == user.id && intent["session_id"] == session.id &&
        intent["state_digest"] == Digest::SHA256.hexdigest(state) && intent["configuration_digest"] == fingerprint &&
        intent["code_verifier"].is_a?(String) && intent["code_verifier"].match?(/\A[A-Za-z0-9_-]{43}\z/) && (code.nil? != error.nil?)
      exchange = lambda do
        raise GoogleLinking::Invalid if error
        raise GoogleLinking::Unavailable unless GoogleCodeFlow.fingerprint(configuration) == fingerprint
        token = GoogleCodeExchange.call(code:, verifier: intent.fetch("code_verifier"), configuration: config)
        raise GoogleLinking::Unavailable unless GoogleCodeFlow.fingerprint(configuration) == fingerprint
        token
      end
      GoogleLinking.complete(user:, session:, state:, exchange:) do |identity|
        raise GoogleLinking::Unavailable unless GoogleCodeFlow.fingerprint(configuration) == fingerprint
        yield identity if block_given?
      end
    end
  end
end
