# frozen_string_literal: true

require "base64"

module Oauth
  class GoogleCodeFlow
    AUTHORIZATION_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
    Configuration = Data.define(:client_id, :client_secret, :redirect_uri)
    FLOWS = {
      "sign_in" => [ "OAUTH_GOOGLE_CODE_FLOW", "GOOGLE_OAUTH_REDIRECT_URI", "/api/v1/auth/google/callback" ],
      "link" => [ "OAUTH_GOOGLE_CODE_LINKING", "GOOGLE_OAUTH_LINK_REDIRECT_URI", "/api/v1/me/oauth-identities/google/callback" ]
    }.freeze

    def self.configuration(flow:)
      flow == "sign_in" ? GoogleSignIn.require_enabled! : GoogleLinking.require_enabled!
      flag, redirect, path = FLOWS.fetch(flow)
      raise GoogleLinking::Unavailable unless ENV[flag] == "on"
      secret = ENV["GOOGLE_OAUTH_CLIENT_SECRET"].to_s
      uri = URI.parse(ENV[redirect].to_s)
      transport = (uri.scheme == "https" && uri.port == 443) ||
        (!Rails.env.production? && uri.scheme == "http" && %w[localhost 127.0.0.1].include?(uri.host))
      raise GoogleLinking::Unavailable unless secret.present? && secret.bytesize <= 4096 && transport &&
        uri.host.present? && uri.path == path && !uri.userinfo && !uri.query && !uri.fragment

      Configuration.new(client_id: GoogleLinking.client_id, client_secret: secret, redirect_uri: uri.to_s)
    rescue URI::InvalidURIError, ArgumentError
      raise GoogleLinking::Unavailable
    end

    def self.enabled?(flow:)
      configuration(flow:)
      true
    rescue GoogleLinking::Unavailable
      false
    end

    def self.url(configuration:, state:, nonce:, verifier:)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      query = URI.encode_www_form(client_id: configuration.client_id, redirect_uri: configuration.redirect_uri, response_type: "code",
        scope: "openid", state:, nonce:, code_challenge: challenge, code_challenge_method: "S256")
      "#{AUTHORIZATION_ENDPOINT}?#{query}"
    end

    def self.fingerprint(config)
      Digest::SHA256.hexdigest(JSON.generate([ config.client_id, config.client_secret, config.redirect_uri ]))
    end
  end
end
