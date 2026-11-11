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
  end
end
