# frozen_string_literal: true

module Api
  module V1
    class BillingController < ProtectedController
      rescue_from Billing::HostedSessions::Conflict do |error|
        render json: { error: { code: error.code, message: error.message } }, status: :conflict
      end
      rescue_from Billing::Configuration::Unavailable, Billing::StripeClient::TransientError do
        response.headers["Retry-After"] = "60"
        render json: { error: { code: "BILLING_UNAVAILABLE", message: "Billing is temporarily unavailable" } }, status: :service_unavailable
      end
      rescue_from Billing::StripeClient::InvalidResponse do
        render json: { error: { code: "BILLING_PROVIDER_ERROR", message: "Billing could not complete this request" } }, status: :bad_gateway
      end

      def checkout
        values = read_parameters(allowed: %w[interval request_id])
        require_parameters!(values, "interval", "request_id")
        raise InvalidParameter, "Invalid interval parameter" unless %w[month year].include?(values.fetch("interval"))
        result = Billing::HostedSessions.checkout(user: Current.user, interval: values.fetch("interval"), request_id: request_id!(values))
        render json: { data: result }
      end

      def portal
        values = read_parameters(allowed: %w[request_id])
        require_parameters!(values, "request_id")
        result = Billing::HostedSessions.portal(user: Current.user, request_id: request_id!(values))
        render json: { data: result }
      end

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

      private

      def request_id!(values)
        value = values.fetch("request_id")
        raise InvalidParameter, "Invalid request_id parameter" unless value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
        ApiRateLimiter.check!(scope: "billing_sessions", identifier: Current.user.id, limit: 10, window: 1.minute)
        value.downcase
      end
    end
  end
end
