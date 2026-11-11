# frozen_string_literal: true

module Api
  module V1
    class BillingController < ProtectedController
      def show
        read_parameters(allowed: [])
        scope = Subscription.joins(:billing_customer).where(billing_customers: { user_id: Current.user.id },
          livemode: Billing::Configuration.mode == "live")
        scope = scope.none unless Billing::Configuration.mode
        subscription = Billing::Entitlements.eligible_subscriptions.where(billing_customers: { user_id: Current.user.id })
          .order(verified_at: :desc, id: :desc).first || scope.order(verified_at: :desc, id: :desc).first
        render json: { data: { plan: PlanCatalog.for_user(Current.user),
          subscription: subscription && {
            status: subscription.status, sync_status: subscription.sync_status,
            current_period_end: subscription.current_period_end, trial_end: subscription.trial_end,
            cancel_at: subscription.cancel_at, cancel_at_period_end: subscription.cancel_at_period_end
          } } }
      end
    end
  end
end
