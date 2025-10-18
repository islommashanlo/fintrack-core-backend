# frozen_string_literal: true

module Api
  class SubscriptionPlansController < ApplicationController
    # GET /api/subscription_plans
    def index
      plans = SubscriptionPlan.active.includes(:user_subscriptions)
      render json: plans.as_json(
        only: %i[id name description price_cents stripe_price_id],
        methods: [:price_in_dollars]
      )
    end
  end
end
