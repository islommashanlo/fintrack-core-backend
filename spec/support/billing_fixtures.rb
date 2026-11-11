# frozen_string_literal: true

module BillingFixtures
  def with_billing_config
    keys = %w[STRIPE_BILLING_MODE STRIPE_WEBHOOK_SECRET STRIPE_SECRET_KEY STRIPE_PRO_PRICE_IDS]
    previous = ENV.to_h.slice(*keys)
    ENV.update("STRIPE_BILLING_MODE" => "test", "STRIPE_WEBHOOK_SECRET" => "whsec_fixture",
      "STRIPE_SECRET_KEY" => "sk_test_fixture", "STRIPE_PRO_PRICE_IDS" => "price_fixture_pro")
    yield
  ensure
    keys.each { |key| previous.key?(key) ? ENV[key] = previous.fetch(key) : ENV.delete(key) }
  end

  def billing_snapshot(**changes)
    data = JSON.parse(Rails.root.join("spec/fixtures/billing/subscription.json").read)
    item = data.fetch("items").fetch("data").sole
    item["current_period_start"] = 1.day.ago.to_i
    item["current_period_end"] = 29.days.from_now.to_i
    data.merge(changes.stringify_keys)
  end

  def stripe_event_body(id: "evt_fixture", type: "customer.subscription.updated", snapshot: billing_snapshot, created: Time.current.to_i, **extra)
    JSON.generate({ id:, type:, object: "event", api_version: Billing::Configuration::API_VERSION, livemode: false,
      created:, data: { object: snapshot }, **extra })
  end

  def stripe_signature(body, at: Time.current.to_i, secret: ENV.fetch("STRIPE_WEBHOOK_SECRET"))
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{at}.#{body}")
    "t=#{at},v1=#{digest}"
  end

  def receive_stripe_event(body = stripe_event_body, signature: stripe_signature(body), **headers)
    post api_v1_stripe_webhook_path, params: body,
      headers: { "CONTENT_TYPE" => "application/json", "Stripe-Signature" => signature, **headers }
  end

  def bind_billing_customer(user, id: "cus_fixture")
    Billing::CustomerLink.bind!(user:, stripe_id: id, livemode: false)
  end

  def stub_subscription(snapshot = billing_snapshot, status: 200)
    stub_request(:get, "https://api.stripe.com/v1/subscriptions/#{snapshot.fetch('id')}")
      .with(headers: { "Authorization" => "Bearer sk_test_fixture", "Stripe-Version" => Billing::Configuration::API_VERSION })
      .to_return(status:, body: snapshot.to_json, headers: { "content-type" => "application/json" })
  end

  def apply_billing_event(id: "evt_fixture", snapshot: billing_snapshot, **options)
    body = stripe_event_body(id:, snapshot:, **options)
    attributes = Billing::StripeEvent.parse(body)
    event = Billing::ReceiveEvent.call(attributes:, payload_digest: Digest::SHA256.hexdigest(body)).event
    stub_subscription(snapshot)
    Billing::ProcessEvent.call(event.id)
    event.reload
  end
end

RSpec.configure { |config| config.include BillingFixtures }
