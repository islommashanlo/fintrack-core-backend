# frozen_string_literal: true

class StripeService
  def self.create_customer(user, payment_method_id = nil)
    customer = Stripe::Customer.create(
      email: user.email,
      name: user.email, # In a real app, you'd want the user's actual name
      payment_method: payment_method_id
    )

    customer.id
  end

  def self.create_subscription(customer_id, price_id)
    Stripe::Subscription.create(
      customer: customer_id,
      items: [{ price: price_id }],
      expand: ['latest_invoice.payment_intent']
    )
  end

  def self.cancel_subscription(subscription_id, cancel_at_period_end: true)
    Stripe::Subscription.update(
      subscription_id,
      cancel_at_period_end: cancel_at_period_end
    )
  end

  def self.retrieve_subscription(subscription_id)
    Stripe::Subscription.retrieve(subscription_id)
  end

  def self.update_payment_method(customer_id, payment_method_id)
    Stripe::Customer.update(
      customer_id,
      invoice_settings: {
        default_payment_method: payment_method_id
      }
    )
  end

  def self.construct_webhook_event(payload, signature)
    Stripe::Webhook.construct_event(
      payload,
      signature,
      ENV.fetch('STRIPE_WEBHOOK_SECRET')
    )
  end

  def self.handle_webhook_event(event)
    case event.type
    when 'customer.subscription.created'
      handle_subscription_created(event.data.object)
    when 'customer.subscription.updated'
      handle_subscription_updated(event.data.object)
    when 'customer.subscription.deleted'
      handle_subscription_deleted(event.data.object)
    when 'invoice.payment_succeeded'
      handle_payment_succeeded(event.data.object)
    when 'invoice.payment_failed'
      handle_payment_failed(event.data.object)
    end
  end

  def self.handle_subscription_created(stripe_subscription)
    user_subscription = UserSubscription.find_by(stripe_subscription_id: stripe_subscription.id)

    return unless user_subscription

    user_subscription.update!(
      status: stripe_subscription.status,
      current_period_start: Time.at(stripe_subscription.current_period_start),
      current_period_end: Time.at(stripe_subscription.current_period_end),
      cancel_at_period_end: stripe_subscription.cancel_at_period_end
    )
  end

  def self.handle_subscription_updated(stripe_subscription)
    user_subscription = UserSubscription.find_by(stripe_subscription_id: stripe_subscription.id)

    return unless user_subscription

    user_subscription.update!(
      status: stripe_subscription.status,
      current_period_start: Time.at(stripe_subscription.current_period_start),
      current_period_end: Time.at(stripe_subscription.current_period_end),
      cancel_at_period_end: stripe_subscription.cancel_at_period_end
    )
  end

  def self.handle_subscription_deleted(stripe_subscription)
    user_subscription = UserSubscription.find_by(stripe_subscription_id: stripe_subscription.id)

    return unless user_subscription

    user_subscription.update!(status: 'canceled')
  end

  def self.handle_payment_succeeded(invoice)
    # Handle successful payment
    # You might want to send a confirmation email or update user status
  end

  def self.handle_payment_failed(invoice)
    # Handle failed payment
    # You might want to notify the user or suspend their subscription
  end
end
