# frozen_string_literal: true

module Billing
  class RecoverCheckout
    # Recovery holds the owning user lock, shared with checkout and webhook processing.
    def self.call(attempt, client:)
      customer = attempt.billing_customer
      unless attempt.stripe_id.present? && customer && customer.user_id == attempt.user_id &&
          customer.livemode == attempt.livemode && attempt.livemode == (Configuration.mode == "live")
        return "skipped"
      end

      data = client.retrieve_checkout(attempt.stripe_id)
      attempt.update!(**CheckoutSnapshot.parse(data, attempt:, customer:), updated_at: Time.current)
      attempt.status
    rescue StripeClient::InvalidResponse
      attempt.update!(status: "needs_review")
      "needs_review"
    rescue StripeClient::TransientError
      # Preserve the existing state and the unknown outcome; a later run can retry.
      "failed"
    end
  end
end
