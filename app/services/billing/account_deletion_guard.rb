# frozen_string_literal: true

module Billing
  class AccountDeletionGuard
    class CancellationRequired < StandardError; end

    def self.check!(user)
      customers = user.billing_customers
      terminal = Subscription.where(status: Subscription::TERMINAL_STATUSES).select(:billing_customer_id)
      nonterminal = Subscription.where.not(status: Subscription::TERMINAL_STATUSES).select(:billing_customer_id)
      pending = BillingEvent.joins(<<~SQL.squish).where(billing_customers: { user_id: user.id }).where(status: %w[pending failed needs_review])
        INNER JOIN billing_customers ON billing_customers.stripe_id = billing_events.stripe_customer_id
          AND billing_customers.livemode = billing_events.livemode
      SQL
      checkouts = user.billing_checkouts.where(status: %w[pending open needs_review]).exists? || user.billing_checkouts.unresolved_completed.exists?
      if checkouts || customers.where.not(id: terminal).exists? || customers.where(id: nonterminal).exists? || pending.exists?
        raise CancellationRequired
      end
    end
  end
end
