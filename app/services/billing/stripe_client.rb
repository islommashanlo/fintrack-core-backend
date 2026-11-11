# frozen_string_literal: true

module Billing
  class StripeClient
    class TransientError < StandardError; end
    class InvalidResponse < StandardError; end

    def retrieve_subscription(id)
      Configuration.require_webhooks!
      raise InvalidResponse unless id.match?(/\Asub_[A-Za-z0-9_]{1,200}\z/)

      connection = Faraday.new(url: "https://api.stripe.com", headers: {
        "Authorization" => "Bearer #{ENV.fetch('STRIPE_SECRET_KEY')}", "Stripe-Version" => Configuration::API_VERSION
      }) do |client|
        client.options.open_timeout = 2
        client.options.timeout = 3
      end
      response = connection.get("/v1/subscriptions/#{id}")
      raise TransientError, "Billing provider temporarily unavailable" if response.status == 429 || response.status.between?(500, 599)
      raise InvalidResponse unless response.status == 200 && response.body.is_a?(String) && response.body.bytesize <= 1_048_576

      JSON.parse(response.body)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError
      raise TransientError, "Billing provider temporarily unavailable"
    rescue JSON::ParserError
      raise InvalidResponse
    end
  end
end
