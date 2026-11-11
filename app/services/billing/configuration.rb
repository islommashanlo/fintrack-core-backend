# frozen_string_literal: true

module Billing
  class Configuration
    API_VERSION = "2026-10-28.endive"
    class Unavailable < StandardError; end

    def self.mode
      value = ENV["STRIPE_BILLING_MODE"]
      return unless %w[test live].include?(value)
      return if Rails.env.production? && value != "live"

      value
    end

    def self.price_ids
      ENV.fetch("STRIPE_PRO_PRICE_IDS", "").split(",").map(&:strip).reject(&:empty?).uniq
    end

    def self.entitlements_enabled?
      mode.present? && price_ids.any? && price_ids.all? { |id| id.match?(/\Aprice_[A-Za-z0-9_]{1,200}\z/) }
    end

    def self.require_webhooks!
      unless entitlements_enabled? && ENV["STRIPE_WEBHOOK_SECRET"].present? && ENV["STRIPE_SECRET_KEY"].present?
        raise Unavailable
      end
    end

    def self.return_url
      value = ENV["STRIPE_BILLING_RETURN_URL"].to_s
      uri = URI.parse(value)
      allowed = uri.scheme == "https" || (!Rails.env.production? && uri.scheme == "http" && %w[localhost 127.0.0.1].include?(uri.host))
      raise Unavailable unless allowed && uri.host && !uri.userinfo && !uri.query && !uri.fragment

      value
    rescue URI::InvalidURIError
      raise Unavailable
    end

    def self.checkout_prices
      { "month" => ENV["STRIPE_PRO_MONTHLY_PRICE_ID"], "year" => ENV["STRIPE_PRO_YEARLY_PRICE_ID"] }
        .select { |_interval, id| price_ids.include?(id) }
    end

    def self.checkout_intervals
      require_webhooks!
      return_url
      checkout_prices.keys
    rescue Unavailable
      []
    end
  end
end
