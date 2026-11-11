# frozen_string_literal: true

module Billing
  class StripeClient
    class TransientError < StandardError; end
    class InvalidResponse < StandardError; end

    def retrieve_subscription(id)
      raise InvalidResponse unless id.match?(/\Asub_[A-Za-z0-9_]{1,200}\z/)

      request(:get, "/v1/subscriptions/#{id}")
    end

    def create_customer(key:)
      request(:post, "/v1/customers", parameters: {}, key:)
    end

    def create_checkout(parameters:, key:)
      request(:post, "/v1/checkout/sessions", parameters:, key:)
    end

    def retrieve_checkout(id)
      raise InvalidResponse unless id.match?(/\Acs_[A-Za-z0-9_]{1,200}\z/)

      request(:get, "/v1/checkout/sessions/#{id}")
    end

    def create_portal(customer_id:, return_url:, key:)
      request(:post, "/v1/billing_portal/sessions", parameters: { customer: customer_id, return_url: }, key:)
    end

    private

    def request(method, path, parameters: nil, key: nil)
      Configuration.require_webhooks!
      connection = Faraday.new(url: "https://api.stripe.com", headers: {
        "Authorization" => "Bearer #{ENV.fetch('STRIPE_SECRET_KEY')}", "Stripe-Version" => Configuration::API_VERSION
      }) do |client|
        client.request :url_encoded
        client.options.open_timeout = 2
        client.options.timeout = 3
      end
      response = connection.run_request(method, path, parameters, key ? { "Idempotency-Key" => key } : {})
      raise TransientError, "Billing provider temporarily unavailable" if [ 409, 429 ].include?(response.status) || response.status.between?(500, 599)
      raise InvalidResponse unless response.status == 200 && response.body.is_a?(String) && response.body.bytesize <= 1_048_576

      JSON.parse(response.body)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError
      raise TransientError, "Billing provider temporarily unavailable"
    rescue JSON::ParserError
      raise InvalidResponse
    end
  end
end
