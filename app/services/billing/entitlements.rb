# frozen_string_literal: true

module Billing
  class Entitlements
    def self.eligible_subscriptions(as_of: Time.current)
      return Subscription.none unless Configuration.entitlements_enabled?

      Subscription.joins(:billing_customer, :billing_event)
        .where(livemode: Configuration.mode == "live", status: %w[active trialing], sync_status: "verified",
          price_id: Configuration.price_ids, collection_paused: false,
          billing_events: { status: "processed", livemode: Configuration.mode == "live" },
          billing_customers: { livemode: Configuration.mode == "live" })
        .where.not(billing_customers: { user_id: nil })
        .where("billing_events.stripe_subscription_id = subscriptions.stripe_id AND billing_events.stripe_customer_id = billing_customers.stripe_id")
        .where("subscriptions.current_period_start <= ? AND subscriptions.current_period_end > ?", as_of, as_of)
        .where("subscriptions.cancel_at IS NULL OR subscriptions.cancel_at > ?", as_of)
        .where("subscriptions.status <> 'trialing' OR subscriptions.trial_end > ?", as_of)
    end

    def self.pro?(user)
      user && eligible_subscriptions.where(billing_customers: { user_id: user.id }).exists?
    end

    def self.pro_user_ids
      return User.none.select(:id) unless Configuration.entitlements_enabled?

      eligible_subscriptions.select("billing_customers.user_id")
    end
  end
end
