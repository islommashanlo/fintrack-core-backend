# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Stripe billing boundaries" do
  include ApiAccounts
  around { |example| with_billing_config { travel_to(Time.utc(2026, 11, 11, 3)) { example.run } } }

  it "accepts signed raw JSON without a browser, queues work, and deduplicates event IDs" do
    body = stripe_event_body
    2.times do
      expect { receive_stripe_event(body) }.to have_enqueued_job(ProcessStripeEventJob).on_queue("default")
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
    expect(response.parsed_body.dig("data", "duplicate")).to be(true)
    expect(BillingEvent.count).to eq(1)
    expect(BillingEvent.sole).to have_attributes(status: "pending", payload_digest: Digest::SHA256.hexdigest(body))
    expect(Subscription.count).to eq(0)
    expect(WebMock).not_to have_requested(:get, /stripe\.com/)
  end

  it "ignores non-authoritative signature debug entries and accepts any valid v1 signature" do
    body = stripe_event_body
    receive_stripe_event(body, signature: "v0=#{'a' * 64},secret=ignored,payload=ignored,destination=ignored,v1=#{'b' * 64},#{stripe_signature(body)}")
    expect(response).to have_http_status(:ok)
    receive_stripe_event(body, signature: "t=#{Time.current.to_i},v0=#{'a' * 64},secret=whsec_fixture,payload=ignored")
    expect(response).to have_http_status(:bad_request)
  end

  it "rejects missing, tampered, expired, future and wrong-secret signatures before parsing or writes" do
    body = stripe_event_body
    [ "", stripe_signature(body, at: 301.seconds.ago.to_i), stripe_signature(body, at: 301.seconds.from_now.to_i),
      stripe_signature(body, secret: "whsec_wrong"), "t=not-a-time,v1=#{'a' * 64}", "#{stripe_signature(body)},t=1" ].each do |signature|
      expect { receive_stripe_event(body, signature:) }.not_to change(BillingEvent, :count)
      expect(response).to have_http_status(:bad_request)
    end
    receive_stripe_event(body + " ", signature: stripe_signature(body))
    expect(response).to have_http_status(:bad_request)
    receive_stripe_event("{broken", signature: "wrong")
    expect(response.parsed_body.dig("error", "code")).to eq("INVALID_WEBHOOK")
    receive_stripe_event("{broken")
    expect(response).to have_http_status(:bad_request)
    receive_stripe_event("")
    expect(response).to have_http_status(:bad_request)
    expect(BillingEvent.count).to eq(0)
  end

  it "fails closed when disabled or missing configuration and rejects wrong modes/versions/accounts" do
    ENV["STRIPE_BILLING_MODE"] = "off"
    receive_stripe_event
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("60")
    ENV["STRIPE_BILLING_MODE"] = "test"
    [ { livemode: true }, { api_version: "2019-02-19" }, { account: "acct_untrusted" }, { context: "acct_other" } ].each do |extra|
      receive_stripe_event(stripe_event_body(**extra))
      expect(response).to have_http_status(:bad_request)
    end
    expect(BillingEvent.count).to eq(0)
  end

  it "bounds request bodies even with chunked delivery and malformed JSON" do
    large = "x" * (Billing::StripeWebhookEndpoint::MAX_BODY_BYTES + 1)
    receive_stripe_event(large)
    expect(response).to have_http_status(413)
    env = Rack::MockRequest.env_for("/api/v1/webhooks/stripe", method: "POST", input: large)
    env.delete("CONTENT_LENGTH")
    env["HTTP_TRANSFER_ENCODING"] = "chunked"
    status, = Billing::StripeWebhookEndpoint.new.call(env)
    expect(status).to eq(413)
    expect(BillingEvent.count).to eq(0)
  end

  it "acknowledges unsupported signed events without treating checkout or invoice data as entitlement" do
    %w[checkout.session.completed invoice.paid].each_with_index do |type, index|
      receive_stripe_event(stripe_event_body(id: "evt_ignored#{index}", type:))
      expect(response).to have_http_status(:ok)
    end
    expect(BillingEvent.pluck(:status)).to eq(%w[ignored ignored])
    expect(enqueued_jobs.select { |job| job[:job] == ProcessStripeEventJob }).to be_empty
    expect(Subscription.count).to eq(0)
  end

  it "rejects a reused event identity with a different subscription target" do
    receive_stripe_event
    receive_stripe_event(stripe_event_body(snapshot: billing_snapshot(id: "sub_other")))
    expect(response).to have_http_status(:conflict)
    expect(BillingEvent.sole.stripe_subscription_id).to eq("sub_fixture")
  end

  it "keeps a durable pending receipt if enqueue fails and retries enqueue on redelivery" do
    allow(ProcessStripeEventJob).to receive(:perform_later).and_return(false)
    receive_stripe_event
    expect(response).to have_http_status(:service_unavailable)
    expect(BillingEvent.sole.status).to eq("pending")
    allow(ProcessStripeEventJob).to receive(:perform_later).and_call_original
    receive_stripe_event
    expect(response).to have_http_status(:ok)
    expect(BillingEvent.count).to eq(1)
    expect(enqueued_jobs.select { |job| job[:job] == ProcessStripeEventJob }.size).to eq(1)
  end

  it "reports a generic temporary failure if the shared limiter is unavailable" do
    allow(FilingsIntel.redis).to receive(:call).and_raise(RedisClient::ConnectionError, "private detail")
    receive_stripe_event
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include("private detail")
    expect(BillingEvent.count).to eq(0)
  end

  it "requires authentication for private subscription status and never exposes another account" do
    get api_v1_billing_subscription_path
    expect(response).to have_http_status(:unauthorized)
    owner = create(:user, email_address: "owner@example.com", password: "password123")
    bind_billing_customer(owner)
    apply_billing_event
    other = create(:user, email_address: "other@example.com", password: "password123")
    api_login(other)
    get api_v1_billing_subscription_path
    expect(response.parsed_body.fetch("data")).to include("plan" => "free", "subscription" => nil)
    api_login(owner)
    get api_v1_billing_subscription_path
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to include("plan" => "pro", "subscription" => include("status" => "active"))
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.body).not_to include("cus_fixture", "sub_fixture", "sk_test_fixture")
  end

  it "unlocks saved screens through verified data and re-gates them after cancellation" do
    user = create(:user, password: "password123")
    bind_billing_customer(user)
    api_login(user)
    get api_v1_saved_screens_path
    expect(response).to have_http_status(:payment_required)
    receive_stripe_event
    stub_subscription
    ProcessStripeEventJob.perform_now(BillingEvent.sole.id)
    get api_v1_me_path
    expect(response.parsed_body.dig("data", "plan")).to eq("pro")
    get api_v1_saved_screens_path
    expect(response).to have_http_status(:ok)
    receive_stripe_event(stripe_event_body(id: "evt_cancel", type: "customer.subscription.deleted", snapshot: billing_snapshot(status: "canceled")))
    ProcessStripeEventJob.perform_now(BillingEvent.order(:id).last.id)
    get api_v1_saved_screens_path
    expect(response).to have_http_status(:payment_required)
  end

  it "blocks local deletion until billing cancellation is verified, then retains detached replay guards" do
    user = create(:user, password: "password123")
    customer = bind_billing_customer(user)
    apply_billing_event
    api_login(user)
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("BILLING_CANCELLATION_REQUIRED")
    apply_billing_event(id: "evt_cancel", type: "customer.subscription.deleted", snapshot: billing_snapshot(status: "canceled"))
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(customer.reload.user_id).to be_nil
    expect(Subscription.count).to eq(1)
    expect(BillingEvent.count).to eq(2)
    new_user = create(:user, email_address: "user@example.com")
    expect { bind_billing_customer(new_user) }.to raise_error(Billing::CustomerLink::Conflict)
  end

  it "enforces screener previews and invalidates paid cursors when verified status changes" do
    user = create(:user, password: "password123")
    bind_billing_customer(user)
    5.times do |index|
      filing = create(:filing, filed_at: 1.day.ago, issuer_cik: format("%010d", index + 100))
      create(:insider_transaction, filing:)
    end
    api_login(user)
    post api_v1_screener_run_path, params: { entity: "companies" }, headers: api_headers, as: :json
    expect(response.parsed_body.fetch("data").size).to eq(3)
    apply_billing_event
    post api_v1_screener_run_path, params: { entity: "companies" }, headers: api_headers, as: :json
    expect(response.parsed_body.fetch("data").size).to eq(5)
    post api_v1_screener_run_path, params: { entity: "companies", limit: 1 }, headers: api_headers, as: :json
    cursor = response.parsed_body.dig("meta", "next_cursor")
    apply_billing_event(id: "evt_past_due", snapshot: billing_snapshot(status: "past_due"))
    post api_v1_screener_run_path, params: { entity: "companies", limit: 1, cursor: }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    post api_v1_screener_run_path, params: { entity: "companies" }, headers: api_headers, as: :json
    expect(response.parsed_body.fetch("data").size).to eq(3)
  end
end
