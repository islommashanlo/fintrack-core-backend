# frozen_string_literal: true

class Api::SubscriptionsController < ApplicationController
  before_action :authenticate_user!

  # GET /api/subscriptions
  def index
    subscriptions = current_user.user_subscriptions.includes(:subscription_plan)
    render json: subscriptions.as_json(
      include: {
        subscription_plan: {
          only: %i[id name description price_cents]
        }
      }
    )
  end

  # POST /api/subscriptions
  def create
    plan = SubscriptionPlan.active.find(params[:subscription_plan_id])

    return render json: { error: 'Subscription plan not found or inactive' }, status: :not_found unless plan

    # Check if user already has an active subscription
    existing_subscription = current_user.user_subscriptions.active.first
    return render json: { error: 'User already has an active subscription' }, status: :conflict if existing_subscription

    begin
      # Create Stripe customer if not exists
      customer_id = current_user.stripe_customer_id || StripeService.create_customer(current_user)

      # Create Stripe subscription
      stripe_subscription = StripeService.create_subscription(customer_id, plan.stripe_price_id)

      # Save to database
      subscription = UserSubscription.create!(
        user: current_user,
        subscription_plan: plan,
        stripe_customer_id: customer_id,
        stripe_subscription_id: stripe_subscription.id,
        status: stripe_subscription.status,
        current_period_start: Time.at(stripe_subscription.current_period_start),
        current_period_end: Time.at(stripe_subscription.current_period_end),
        cancel_at_period_end: stripe_subscription.cancel_at_period_end
      )

      # Update user's stripe_customer_id if it was created
      current_user.update!(stripe_customer_id: customer_id) unless current_user.stripe_customer_id

      render json: subscription.as_json(include: :subscription_plan), status: :created
    rescue Stripe::StripeError => e
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      render json: { error: 'Failed to create subscription' }, status: :internal_server_error
    end
  end

  # GET /api/subscriptions/:id
  def show
    subscription = current_user.user_subscriptions.find(params[:id])
    render json: subscription.as_json(include: :subscription_plan)
  end

  # PUT/PATCH /api/subscriptions/:id
  def update
    subscription = current_user.user_subscriptions.find(params[:id])

    if params[:cancel].to_s == 'true'
      # Cancel subscription
      begin
        StripeService.cancel_subscription(subscription.stripe_subscription_id)
        subscription.update!(status: 'canceled')
        render json: { message: 'Subscription canceled successfully' }
      rescue Stripe::StripeError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
    else
      render json: { error: 'Invalid update parameters' }, status: :bad_request
    end
  end

  # DELETE /api/subscriptions/:id
  def destroy
    subscription = current_user.user_subscriptions.find(params[:id])

    begin
      # Cancel the Stripe subscription immediately
      StripeService.cancel_subscription(subscription.stripe_subscription_id, cancel_at_period_end: false)
      subscription.destroy

      render json: { message: 'Subscription canceled and deleted' }
    rescue Stripe::StripeError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
end
