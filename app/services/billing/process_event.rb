# frozen_string_literal: true

module Billing
  class ProcessEvent
    def self.call(event_id, client: StripeClient.new)
      event = BillingEvent.find_by(id: event_id)
      return unless event && %w[pending failed].include?(event.status)

      customer = BillingCustomer.find_by(stripe_id: event.stripe_customer_id, livemode: event.livemode)
      user = customer&.user
      unless user
        event.with_lock { finish(event, "ignored", "unmatched_customer") if %w[pending failed].include?(event.status) }
        return
      end
      retry_error = nil
      user.with_lock do
        customer.reload
        event.with_lock do
          next unless %w[pending failed].include?(event.status)
          next finish(event, "ignored", "mode_changed") unless Configuration.entitlements_enabled? && event.livemode == (Configuration.mode == "live")

          event.increment!(:attempts)
          subscription = Subscription.find_by(stripe_id: event.stripe_subscription_id, livemode: event.livemode)
          if subscription && subscription.billing_customer_id != customer.id
            next finish(event, "needs_review", "customer_mismatch")
          end
          if subscription && Subscription::TERMINAL_STATUSES.include?(subscription.status)
            next finish(event, "ignored", "terminal_subscription")
          end
          subscription ||= customer.subscriptions.build(stripe_id: event.stripe_subscription_id, livemode: event.livemode)
          begin
            attributes = if event.event_type == "customer.subscription.deleted"
              { status: "canceled" }
            else
              SubscriptionSnapshot.parse(client.retrieve_subscription(event.stripe_subscription_id), event:)
            end
            subscription.update!(**attributes, billing_event: event, sync_status: "verified", verified_at: Time.current)
            finish(event, "processed", nil)
          rescue StripeClient::InvalidResponse
            subscription.update!(sync_status: "needs_review") if subscription.persisted?
            finish(event, "needs_review", "invalid_provider_snapshot")
          rescue StripeClient::TransientError => error
            event.update!(status: "failed", reason: "provider_unavailable")
            retry_error = error
          rescue Configuration::Unavailable
            event.update!(status: "failed", reason: "configuration_unavailable")
          end
        end
      end
      raise retry_error if retry_error
    rescue ActiveRecord::RecordNotFound
      event&.update!(status: "ignored", reason: "account_removed", processed_at: Time.current)
    end

    def self.finish(event, status, reason)
      event.update!(status:, reason:, processed_at: Time.current)
    end
    private_class_method :finish
  end
end
