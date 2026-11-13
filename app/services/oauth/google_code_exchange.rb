# frozen_string_literal: true

require "timeout"

module Oauth
  class GoogleCodeExchange
    TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
    BODY_LIMIT = 65_536

    def self.call(code:, verifier:, configuration:)
      raise GoogleLinking::Invalid unless code.is_a?(String) && code.bytesize.between?(1, 4096) &&
        code.valid_encoding? && !code.match?(/[[:cntrl:]]/)

      body = +""
      connection = Faraday.new do |client|
        client.request :url_encoded
        client.options.open_timeout = 2
        client.options.timeout = 5
      end
      response = Timeout.timeout(5) do
        connection.post(TOKEN_ENDPOINT) do |request|
          request.body = { grant_type: "authorization_code", code:, code_verifier: verifier,
            client_id: configuration.client_id, client_secret: configuration.client_secret, redirect_uri: configuration.redirect_uri }
          request.options.on_data = lambda do |chunk, size, *_|
            raise GoogleLinking::Unavailable if size > BODY_LIMIT
            body << chunk
          end
        end
      end
      raise GoogleLinking::Invalid if [ 400, 401, 403 ].include?(response.status)
      raise GoogleLinking::Unavailable unless response.status == 200
      body = response.body if body.empty?
      raise GoogleLinking::Unavailable unless body.is_a?(String) && body.bytesize <= BODY_LIMIT
      payload = JSON.parse(body)
      raise GoogleLinking::Unavailable unless payload.is_a?(Hash) && payload["id_token"].is_a?(String) && payload["id_token"].bytesize.between?(1, 16_384)

      payload.fetch("id_token")
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError, Timeout::Error, JSON::ParserError
      raise GoogleLinking::Unavailable
    end
  end
end
