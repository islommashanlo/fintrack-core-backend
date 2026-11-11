# frozen_string_literal: true

module Billing
  # Internal seam for future checkout; never called from webhook metadata or public params.
  class CustomerLink
    class Conflict < StandardError; end

    def self.bind!(user:, stripe_id:, livemode:)
      user.with_lock do
        existing = BillingCustomer.find_by(stripe_id:, livemode:)
        raise Conflict if existing && existing.user_id != user.id

        existing || user.billing_customers.create!(stripe_id:, livemode:)
      end
    rescue ActiveRecord::RecordNotUnique
      raise Conflict
    end
  end
end
