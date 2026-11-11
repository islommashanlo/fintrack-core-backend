# frozen_string_literal: true

module Billing
  class CheckoutSnapshot
    def self.parse(data, attempt:, customer:)
      unless data.is_a?(Hash) && data["object"] == "checkout.session" && data["mode"] == "subscription" &&
          data["customer"] == customer.stripe_id && data["livemode"] == attempt.livemode &&
          customer.livemode == attempt.livemode && data["client_reference_id"] == attempt.request_id &&
          data["id"].is_a?(String) && data["id"].match?(/\Acs_[A-Za-z0-9_]{1,200}\z/) &&
          %w[open complete expired].include?(data["status"]) &&
          data["expires_at"].is_a?(Integer) && data["expires_at"].between?(1, 253_402_300_799) &&
          (attempt.stripe_id.nil? || attempt.stripe_id == data["id"])
        raise StripeClient::InvalidResponse
      end
      subscription = data["subscription"]
      unless subscription.nil? || (subscription.is_a?(String) && subscription.match?(/\Asub_[A-Za-z0-9_]{1,200}\z/))
        raise StripeClient::InvalidResponse
      end
      if attempt.stripe_subscription_id && subscription != attempt.stripe_subscription_id
        raise StripeClient::InvalidResponse
      end
      if %w[complete expired].include?(attempt.status) && data["status"] != attempt.status
        raise StripeClient::InvalidResponse
      end
      { stripe_id: data.fetch("id"), stripe_subscription_id: subscription,
        status: data.fetch("status"), expires_at: Time.at(data.fetch("expires_at")).utc }
    end
  end
end
