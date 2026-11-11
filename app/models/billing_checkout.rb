# frozen_string_literal: true

class BillingCheckout < ApplicationRecord
  belongs_to :user
  belongs_to :billing_customer, optional: true
  validates :request_id, :price_id, :success_url, :cancel_url, presence: true
  validates :status, inclusion: { in: %w[pending open complete expired needs_review] }
  validates :interval, inclusion: { in: %w[month year] }

  scope :unresolved_completed, -> {
    # A retained subscription identity must not be cleared by another session status.
    where("billing_checkouts.status = 'complete' OR billing_checkouts.stripe_subscription_id IS NOT NULL").where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM subscriptions
        WHERE subscriptions.stripe_id = billing_checkouts.stripe_subscription_id
          AND subscriptions.billing_customer_id = billing_checkouts.billing_customer_id
          AND subscriptions.livemode = billing_checkouts.livemode
          AND subscriptions.status IN ('canceled', 'incomplete_expired')
          AND subscriptions.sync_status = 'verified'
      )
    SQL
  }
end
