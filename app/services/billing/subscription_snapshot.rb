# frozen_string_literal: true

module Billing
  class SubscriptionSnapshot
    def self.parse(data, event:)
      invalid! unless data.is_a?(Hash) && data["object"] == "subscription" && data["id"] == event.stripe_subscription_id &&
        data["customer"] == event.stripe_customer_id && data["livemode"] == event.livemode
      invalid! unless Subscription::STATUSES.include?(data["status"]) && [ true, false ].include?(data["cancel_at_period_end"])
      list = data["items"]
      invalid! unless list.is_a?(Hash) && list["has_more"] == false && list["data"].is_a?(Array) && list["data"].size == 1
      item = list.fetch("data").sole
      invalid! unless item.is_a?(Hash) && item["quantity"].is_a?(Integer) && item["quantity"] == 1 && item["price"].is_a?(Hash)
      price = item.fetch("price")
      invalid! unless price["id"].is_a?(String) && price["id"].match?(/\Aprice_[A-Za-z0-9_]{1,200}\z/)
      invalid! unless price["type"] == "recurring" && price["livemode"] == event.livemode
      start_at = timestamp(item["current_period_start"])
      end_at = timestamp(item["current_period_end"])
      invalid! unless end_at > start_at
      trial_end = timestamp(data["trial_end"], optional: true)
      invalid! if data["status"] == "trialing" && trial_end.nil?
      invalid! if %w[active trialing].include?(data["status"]) && data["ended_at"].present?
      { status: data.fetch("status"), price_id: price.fetch("id"), current_period_start: start_at,
        current_period_end: end_at, trial_end:, cancel_at: timestamp(data["cancel_at"], optional: true),
        cancel_at_period_end: data.fetch("cancel_at_period_end"), collection_paused: data["pause_collection"].present? }
    end

    def self.timestamp(value, optional: false)
      return if value.nil? && optional
      invalid! unless value.is_a?(Integer) && value.between?(1, 253_402_300_799)
      Time.at(value).utc
    end

    def self.invalid!
      raise StripeClient::InvalidResponse
    end
  end
end
