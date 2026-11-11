# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Hosted billing sessions" do
  include ApiAccounts
  around { |example| with_billing_config { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }
  let(:request_id) { SecureRandom.uuid }

  def checkout_payload(customer: "cus_fixture", reference: request_id, status: "open", **extra)
    { id: "cs_test_fixture", object: "checkout.session", mode: "subscription", customer:,
      livemode: false, client_reference_id: reference, status:, expires_at: 30.minutes.from_now.to_i,
      url: "https://checkout.stripe.com/c/pay/cs_test_fixture", **extra }
  end

  def checkout(**extra)
    post api_v1_billing_checkout_path, params: { interval: "month", request_id:, **extra }, headers: api_headers, as: :json
  end

  def portal(**extra)
    post api_v1_billing_portal_path, params: { request_id:, **extra }, headers: api_headers, as: :json
  end

  def stub_customer
    stub_request(:post, "https://api.stripe.com/v1/customers")
      .with(headers: { "Idempotency-Key" => /\Afilingsintel-[0-9a-f]{64}\z/ })
      .to_return(status: 200, body: { id: "cus_fixture", object: "customer", livemode: false }.to_json)
  end

  def stub_checkout(payload = checkout_payload)
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with(body: { "mode" => "subscription", "customer" => "cus_fixture", "client_reference_id" => request_id,
        "line_items" => [ { "price" => "price_fixture_pro", "quantity" => "1" } ],
        "success_url" => "https://app.example.com/settings/billing?checkout=success",
        "cancel_url" => "https://app.example.com/settings/billing?checkout=canceled" })
      .to_return(status: 200, body: payload.to_json)
  end

  it "creates one owned customer and checkout with a frozen approved price and trusted callbacks" do
    api_login(user)
    stub_customer
    stub_checkout
    checkout
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to include("url" => "https://checkout.stripe.com/c/pay/cs_test_fixture", "request_id" => request_id)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(user.billing_customers.sole.stripe_id).to eq("cus_fixture")
    expect(user.billing_checkouts.sole).to have_attributes(status: "open", stripe_id: "cs_test_fixture", price_id: "price_fixture_pro")
    expect(Subscription.count).to eq(0)
    expect(PlanCatalog.for_user(user)).to eq("free")
    stub_request(:get, "https://api.stripe.com/v1/checkout/sessions/cs_test_fixture").to_return(status: 200, body: checkout_payload.to_json)
    checkout
    expect(response).to have_http_status(:ok)
    expect(WebMock).to have_requested(:post, "https://api.stripe.com/v1/customers").once
    expect(WebMock).to have_requested(:post, "https://api.stripe.com/v1/checkout/sessions").once
  end

  it "reuses the same pending key and intent after a transport timeout" do
    api_login(user)
    stub_customer
    keys = []
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions").to_return do |request|
      keys << request.headers.fetch("Idempotency-Key")
      if keys.size == 1
        raise Faraday::TimeoutError
      end
      { status: 200, body: checkout_payload.to_json }
    end
    checkout
    expect(response).to have_http_status(:service_unavailable)
    expect(user.billing_checkouts.sole.status).to eq("pending")
    expect(user.billing_customers.count).to eq(1)
    checkout
    expect(response).to have_http_status(:ok)
    expect(keys.uniq.size).to eq(1)
    expect(user.billing_checkouts.count).to eq(1)
  end

  it "resumes the current attempt instead of opening a second one for a new request UUID" do
    api_login(user)
    stub_customer
    stub_checkout
    checkout
    stub_request(:get, "https://api.stripe.com/v1/checkout/sessions/cs_test_fixture").to_return(status: 200, body: checkout_payload.to_json)
    checkout(request_id: SecureRandom.uuid)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "request_id")).to eq(request_id)
    expect(user.billing_checkouts.count).to eq(1)
    expect(WebMock).to have_requested(:post, "https://api.stripe.com/v1/checkout/sessions").once
  end

  it "records completion without granting access or creating another session" do
    api_login(user)
    stub_customer
    stub_checkout(checkout_payload(status: "complete", url: nil))
    checkout
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("CHECKOUT_PENDING_CONFIRMATION")
    expect(user.billing_checkouts.sole.status).to eq("complete")
    expect(PlanCatalog.for_user(user)).to eq("free")
    checkout(request_id: SecureRandom.uuid)
    expect(response).to have_http_status(:conflict)
    expect(WebMock).to have_requested(:post, "https://api.stripe.com/v1/checkout/sessions").once
  end

  it "requires a new request after verified expiry and never retries an unknown outcome after the safety window" do
    api_login(user)
    stub_customer
    stub_checkout(checkout_payload(status: "expired", url: nil))
    checkout
    expect(response).to have_http_status(:conflict)
    expect(user.billing_checkouts.sole.status).to eq("expired")
    checkout
    expect(response.parsed_body.dig("error", "code")).to eq("CHECKOUT_EXPIRED")
    user.billing_checkouts.sole.update!(status: "pending", stripe_id: nil, created_at: 23.hours.ago)
    checkout
    expect(response.parsed_body.dig("error", "code")).to eq("CHECKOUT_REVIEW_REQUIRED")
    expect(WebMock).to have_requested(:post, "https://api.stripe.com/v1/checkout/sessions").once
  end

  it "keeps a completed checkout unresolved until its own subscription is verified terminal" do
    bind_billing_customer(user)
    apply_billing_event(snapshot: billing_snapshot(status: "canceled"))
    api_login(user)
    stub_checkout(checkout_payload(status: "complete", url: nil, subscription: "sub_new"))
    checkout
    expect(user.billing_checkouts.sole.stripe_subscription_id).to eq("sub_new")
    expect(response.parsed_body.dig("error", "code")).to eq("CHECKOUT_PENDING_CONFIRMATION")
    checkout(request_id: SecureRandom.uuid)
    expect(response.parsed_body.dig("error", "code")).to eq("CHECKOUT_PENDING_CONFIRMATION")
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response.parsed_body.dig("error", "code")).to eq("BILLING_CANCELLATION_REQUIRED")
    expect(user.billing_checkouts.count).to eq(1)

    apply_billing_event(id: "evt_new_terminal", snapshot: billing_snapshot(id: "sub_new", status: "canceled"))
    next_request_id = SecureRandom.uuid
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .to_return(status: 200, body: checkout_payload(reference: next_request_id).to_json)
    checkout(request_id: next_request_id)
    expect(response).to have_http_status(:ok)
    expect(user.billing_checkouts.count).to eq(2)
  end

  it "uses only the owned customer for a portal URL and never grants status from that response" do
    bind_billing_customer(user)
    api_login(user)
    stub_request(:post, "https://api.stripe.com/v1/billing_portal/sessions")
      .with(body: { "customer" => "cus_fixture", "return_url" => "https://app.example.com/settings/billing" })
      .to_return(status: 200, body: { object: "billing_portal.session", customer: "cus_fixture", livemode: false, url: "https://billing.stripe.com/p/session/fixture" }.to_json)
    portal
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "url")).to eq("https://billing.stripe.com/p/session/fixture")
    expect(PlanCatalog.for_user(user)).to eq("free")
    other = create(:user, email_address: "other@example.com", password: "password123")
    api_login(other)
    portal
    expect(response).to have_http_status(:conflict)
    expect(WebMock).to have_requested(:post, "https://api.stripe.com/v1/billing_portal/sessions").once
  end

  it "rejects unsafe provider URLs and stores checkout failures for review" do
    api_login(user)
    stub_customer
    stub_checkout(checkout_payload(url: "https://checkout.stripe.com.evil.example/session"))
    checkout
    expect(response).to have_http_status(:bad_gateway)
    expect(user.billing_checkouts.sole.status).to eq("needs_review")
    expect(response.body).not_to include("evil.example")
    expect(PlanCatalog.for_user(user)).to eq("free")
  end

  it "rejects a provider customer response already bound to another account" do
    owner = create(:user, email_address: "customer-owner@example.com")
    bind_billing_customer(owner)
    api_login(user)
    stub_customer
    checkout
    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body.dig("error", "code")).to eq("BILLING_PROVIDER_ERROR")
    expect(user.billing_customers.count).to eq(0)
    expect(user.billing_checkouts.sole.status).to eq("needs_review")
    expect(owner.billing_customers.sole.stripe_id).to eq("cus_fixture")
    expect(WebMock).not_to have_requested(:post, "https://api.stripe.com/v1/checkout/sessions")
  end

  it "refuses new checkout for an existing nonterminal subscription while portal remains available" do
    bind_billing_customer(user)
    apply_billing_event(snapshot: billing_snapshot(status: "past_due"))
    api_login(user)
    checkout
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("BILLING_ALREADY_EXISTS")
    expect(user.billing_checkouts.count).to eq(0)
    expect(WebMock).not_to have_requested(:post, "https://api.stripe.com/v1/checkout/sessions")
  end

  it "requires auth/CSRF and rejects forged customer, amount, plan and redirect fields" do
    checkout
    expect(response).to have_http_status(:forbidden)
    api_login(user)
    [ { customer_id: "cus_other" }, { price_id: "price_other" }, { amount: 1 }, { plan: "pro" },
      { return_url: "https://evil.example" }, { interval: "week" }, { request_id: "not-a-uuid" } ].each do |extra|
      checkout(**extra)
      expect(response).to have_http_status(:bad_request)
    end
    portal(customer_id: "cus_other")
    expect(response).to have_http_status(:bad_request)
    expect(BillingCheckout.count).to eq(0)
    expect(WebMock).not_to have_requested(:post, /stripe\.com/)
  end

  it "keeps billing disabled and exposes only configured checkout intervals in the plan catalog" do
    get api_v1_plans_path
    expect(response.parsed_body.fetch("data").find { |plan| plan.fetch("id") == "pro" }.fetch("checkout_intervals")).to eq([ "month" ])
    api_login(user)
    checkout(interval: "year")
    expect(response).to have_http_status(:service_unavailable)
    ENV["STRIPE_BILLING_MODE"] = "off"
    get api_v1_plans_path
    expect(response.parsed_body.fetch("data")).to all(include("checkout_intervals" => []))
    checkout
    expect(response).to have_http_status(:service_unavailable)
    expect(BillingCheckout.count).to eq(0)
  end
end
