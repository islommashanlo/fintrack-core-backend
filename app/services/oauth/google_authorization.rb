# frozen_string_literal: true

module Oauth
  class GoogleAuthorization
    CALLBACK_PATH = "/api/v1/auth/google/callback"
    AUTHORIZATION_ENDPOINT = GoogleCodeFlow::AUTHORIZATION_ENDPOINT
    Configuration = GoogleCodeFlow::Configuration
    Result = Data.define(:authorization_url, :expires_at, :intent)

    def self.configuration
      GoogleCodeFlow.configuration(flow: "sign_in")
    end

    def self.start(previous_intent: nil)
      config = configuration
      result = GoogleSignIn.start(previous_intent:)
      verifier = SecureRandom.urlsafe_base64(32)
      intent = result.intent.merge("flow" => "code", "code_verifier" => verifier, "configuration_digest" => fingerprint(config))
      Result.new(authorization_url: GoogleCodeFlow.url(configuration: config, state: result.state, nonce: result.nonce, verifier:), expires_at: result.expires_at, intent:)
    end

    def self.complete(intent:, state:, code: nil, error: nil)
      raise ArgumentError, "Session creation block is required" unless block_given?
      config = configuration
      raise GoogleLinking::Invalid unless intent.is_a?(Hash) && intent["flow"] == "code" &&
        intent["configuration_digest"] == fingerprint(config) && intent["code_verifier"].is_a?(String) &&
        intent["code_verifier"].match?(/\A[A-Za-z0-9_-]{43}\z/) && (code.nil? != error.nil?)

      exchange = lambda do
        raise GoogleLinking::Invalid if error
        raise GoogleLinking::Unavailable unless fingerprint(configuration) == fingerprint(config)
        token = GoogleCodeExchange.call(code:, verifier: intent.fetch("code_verifier"), configuration: config)
        raise GoogleLinking::Unavailable unless fingerprint(configuration) == fingerprint(config)
        token
      end
      GoogleSignIn.complete(intent:, state:, exchange:) do |user|
        raise GoogleLinking::Unavailable unless fingerprint(configuration) == fingerprint(config)
        yield user
      end
    end

    def self.fingerprint(config)
      GoogleCodeFlow.fingerprint(config)
    end
    private_class_method :fingerprint
  end
end
