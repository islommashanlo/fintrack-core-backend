# frozen_string_literal: true

require "base64"

module Oauth
  class GoogleAuthorization
    CALLBACK_PATH = "/api/v1/auth/google/callback"
    AUTHORIZATION_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
    Configuration = Data.define(:client_id, :client_secret, :redirect_uri)
    Result = Data.define(:authorization_url, :expires_at, :intent)

    def self.configuration
      GoogleSignIn.require_enabled!
      raise GoogleLinking::Unavailable unless ENV["OAUTH_GOOGLE_CODE_FLOW"] == "on"
      secret = ENV["GOOGLE_OAUTH_CLIENT_SECRET"].to_s
      uri = URI.parse(ENV["GOOGLE_OAUTH_REDIRECT_URI"].to_s)
      transport = (uri.scheme == "https" && uri.port == 443) ||
        (!Rails.env.production? && uri.scheme == "http" && %w[localhost 127.0.0.1].include?(uri.host))
      raise GoogleLinking::Unavailable unless secret.present? && secret.bytesize <= 4096 && transport &&
        uri.host.present? && uri.path == CALLBACK_PATH && !uri.userinfo && !uri.query && !uri.fragment

      Configuration.new(client_id: GoogleLinking.client_id, client_secret: secret, redirect_uri: uri.to_s)
    rescue URI::InvalidURIError, ArgumentError
      raise GoogleLinking::Unavailable
    end

    def self.start(previous_intent: nil)
      config = configuration
      result = GoogleSignIn.start(previous_intent:)
      verifier = SecureRandom.urlsafe_base64(32)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      query = URI.encode_www_form(client_id: config.client_id, redirect_uri: config.redirect_uri, response_type: "code",
        scope: "openid", state: result.state, nonce: result.nonce, code_challenge: challenge, code_challenge_method: "S256")
      intent = result.intent.merge("flow" => "code", "code_verifier" => verifier, "configuration_digest" => fingerprint(config))
      Result.new(authorization_url: "#{AUTHORIZATION_ENDPOINT}?#{query}", expires_at: result.expires_at, intent:)
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
      Digest::SHA256.hexdigest(JSON.generate([ config.client_id, config.client_secret, config.redirect_uri ]))
    end
    private_class_method :fingerprint
  end
end
