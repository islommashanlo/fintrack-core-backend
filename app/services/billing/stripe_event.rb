# frozen_string_literal: true

module Billing
  class StripeEvent
    class Invalid < StandardError; end
    TYPES = %w[customer.subscription.created customer.subscription.updated customer.subscription.deleted
      customer.subscription.paused customer.subscription.resumed].freeze

    def self.parse(body)
      data = JSON.parse(body)
      invalid! unless data.is_a?(Hash) && data["object"] == "event" && data["api_version"] == Configuration::API_VERSION
      invalid! unless [ true, false ].include?(data["livemode"]) && data["livemode"] == (Configuration.mode == "live")
      invalid! if data["account"].present? || data["context"].present?
      invalid! unless data["id"].is_a?(String) && data["id"].match?(/\Aevt_[A-Za-z0-9_]{1,200}\z/)
      invalid! unless data["type"].is_a?(String) && data["type"].match?(/\A[a-z0-9_.]{1,120}\z/)
      created = data["created"]
      invalid! unless created.is_a?(Integer) && created.positive? && created <= Time.current.to_i + 300
      attributes = { stripe_id: data.fetch("id"), event_type: data.fetch("type"), api_version: data.fetch("api_version"),
        livemode: data.fetch("livemode"), provider_created_at: Time.at(created).utc,
        stripe_customer_id: nil, stripe_subscription_id: nil }
      return attributes unless TYPES.include?(data.fetch("type"))

      object = data.dig("data", "object")
      invalid! unless object.is_a?(Hash) && object["object"] == "subscription" && object["livemode"] == data["livemode"]
      invalid! unless object["id"].is_a?(String) && object["id"].match?(/\Asub_[A-Za-z0-9_]{1,200}\z/)
      invalid! unless object["customer"].is_a?(String) && object["customer"].match?(/\Acus_[A-Za-z0-9_]{1,200}\z/)
      invalid! if data["type"] == "customer.subscription.deleted" && object["status"] != "canceled"
      attributes.merge(stripe_customer_id: object.fetch("customer"), stripe_subscription_id: object.fetch("id"))
    rescue JSON::ParserError, TypeError
      invalid!
    end

    def self.invalid!
      raise Invalid
    end
  end
end
