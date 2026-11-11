# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::Recovery do
  around { |example| with_billing_config { travel_to(Time.utc(2026, 11, 11, 5)) { example.run } } }
  let(:user) { create(:user) }
  let!(:customer) { bind_billing_customer(user) }

  def event(id: "evt_recovery", status: "pending", **options)
    body = stripe_event_body(id:, **options)
    row = Billing::ReceiveEvent.call(attributes: Billing::StripeEvent.parse(body), payload_digest: Digest::SHA256.hexdigest(body)).event
    row.update!(status:, updated_at: 20.minutes.ago)
    row
  end

  def attempt(**attributes)
    user.billing_checkouts.create!(billing_customer: customer, livemode: false, request_id: SecureRandom.uuid,
      interval: "month", price_id: "price_fixture_pro", stripe_id: "cs_recovery", status: "open",
      success_url: "https://app.example.com/billing?checkout=success", cancel_url: "https://app.example.com/billing?checkout=canceled",
      updated_at: 20.minutes.ago, **attributes)
  end

  def stub_checkout(row, **extra)
    data = { id: row.stripe_id, object: "checkout.session", mode: "subscription", customer: customer.stripe_id,
      livemode: false, client_reference_id: row.request_id, status: "expired", expires_at: 1.minute.ago.to_i, **extra }
    stub_request(:get, "https://api.stripe.com/v1/checkout/sessions/#{row.stripe_id}").to_return(status: 200, body: data.to_json)
  end

  def recovery(kind = "events", **options)
    described_class.new(kind:, **options)
  end

  it "previews bounded stale work without writes, jobs or HTTP, excluding fresh/quarantined/unmatched records" do
    stale = event
    event(id: "evt_fresh").update!(updated_at: Time.current)
    event(id: "evt_review", status: "needs_review")
    event(id: "evt_unknown", snapshot: billing_snapshot(customer: "cus_unknown"), status: "ignored").update!(reason: "unmatched_customer")
    stale_checkout = attempt
    attempt(stripe_id: nil, status: "pending")
    clear_enqueued_jobs
    before = [ BillingEvent.order(:id).pluck(:status, :updated_at), BillingCheckout.order(:id).pluck(:status, :updated_at) ]
    expect(recovery.plan.to_h).to include(eligible_count: 1, selected_count: 1, max_provider_requests: 1, review_count: 1, blocked_count: 1)
    expect(recovery.plan.items.map(&:id)).to eq([ stale.id ])
    expect(recovery("checkouts").plan.items.map(&:id)).to eq([ stale_checkout.id ])
    expect(recovery("checkouts").plan.blocked_count).to eq(1)
    expect(OpsMetrics.new.to_h.fetch(:billing)).to include(checkouts: { "open" => 1, "pending" => 1 }, checkouts_without_session: 1)
    expect([ BillingEvent.order(:id).pluck(:status, :updated_at), BillingCheckout.order(:id).pluck(:status, :updated_at) ]).to eq(before)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:any, /stripe\.com/)
  end

  it "recovers stranded receipts synchronously, retaining verified sources and applying signed deletion without a request" do
    pending = event
    failed = event(id: "evt_failed", status: "failed")
    deleted = event(id: "evt_deleted", type: "customer.subscription.deleted", snapshot: billing_snapshot(id: "sub_deleted", status: "canceled"))
    clear_enqueued_jobs
    stub_subscription
    runner = recovery
    plan = runner.plan
    expect(plan.request_count).to eq(2)
    result = runner.execute(plan, max_requests: 2)
    expect(result).to include(provider_requests: 2, failed: false)
    expect([ pending, failed, deleted ].map { |row| row.reload.status }).to eq(%w[processed processed processed])
    expect([ pending, failed, deleted ].map(&:attempts)).to eq([ 1, 1, 1 ])
    expect(customer.subscriptions.find_by!(stripe_id: "sub_fixture").billing_event).to eq(failed)
    expect(customer.subscriptions.find_by!(stripe_id: "sub_deleted").status).to eq("canceled")
    expect(PlanCatalog.for_user(user)).to eq("pro")
    expect(enqueued_jobs).to be_empty
    expect(WebMock).to have_requested(:get, "https://api.stripe.com/v1/subscriptions/sub_fixture").twice
    expect(WebMock).not_to have_requested(:post, /stripe\.com/)
  end

  it "refuses an insufficient budget or disabled/missing configuration before changing rows or making HTTP calls" do
    row = event
    runner = recovery
    plan = runner.plan
    expect { runner.execute(plan, max_requests: 0) }.to raise_error(described_class::BudgetExceeded)
    ENV["STRIPE_SECRET_KEY"] = ""
    expect { runner.execute(plan, max_requests: 1) }.to raise_error(Billing::Configuration::Unavailable)
    ENV["STRIPE_BILLING_MODE"] = "off"
    expect(recovery.plan.to_h).to include(mode: "off", selected_count: 0, max_provider_requests: 0)
    expect(row.reload).to have_attributes(status: "pending", attempts: 0)
    expect(WebMock).not_to have_requested(:any, /stripe\.com/)
  end

  it "records a single transient event failure without scheduling more retries or exposing provider responses" do
    row = event
    clear_enqueued_jobs
    stub_subscription(status: 503)
    runner = recovery
    result = runner.execute(runner.plan, max_requests: 1)
    expect(result).to include(provider_requests: 1, failed: true, results: [ { id: row.id, status: "failed" } ])
    expect(row.reload).to have_attributes(status: "failed", reason: "provider_unavailable", attempts: 1)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).to have_requested(:get, "https://api.stripe.com/v1/subscriptions/sub_fixture").once
    expect(recovery.plan.items).to be_empty
  end

  it "keeps deterministic event failures quarantined until explicitly selected for review" do
    apply_billing_event(id: "evt_original")
    row = event
    data = billing_snapshot
    data.fetch("items")["data"] = []
    stub_subscription(data)
    runner = recovery
    expect(runner.execute(runner.plan, max_requests: 1)).to include(failed: true)
    expect(row.reload.status).to eq("needs_review")
    expect(PlanCatalog.for_user(user)).to eq("free")
    row.update!(updated_at: 20.minutes.ago)
    expect(recovery.plan.items).to be_empty
    expect { recovery(include_review: true) }.to raise_error(described_class::InvalidOptions)
    stub_subscription
    runner = recovery(ids: [ row.id ], include_review: true)
    expect(runner.execute(runner.plan, max_requests: 1)).to include(failed: false)
    expect(row.reload.status).to eq("processed")
    expect(PlanCatalog.for_user(user)).to eq("pro")
  end

  it "requires provider-confirmed expiry rather than assuming it from the local clock" do
    row = attempt(expires_at: 1.hour.ago)
    stub_checkout(row, status: "open", expires_at: 1.hour.ago.to_i)
    runner = recovery("checkouts")
    expect(runner.execute(runner.plan, max_requests: 1).fetch(:results)).to eq([ { id: row.id, status: "open" } ])
    expect(row.reload.status).to eq("open")
    row.update!(updated_at: 20.minutes.ago)
    stub_checkout(row)
    runner = recovery("checkouts")
    expect(runner.execute(runner.plan, max_requests: 1).fetch(:results)).to eq([ { id: row.id, status: "expired" } ])
    expect(row.reload.status).to eq("expired")
    expect(Subscription.count).to eq(0)
    expect(PlanCatalog.for_user(user)).to eq("free")
    expect(recovery("checkouts").plan.items).to be_empty
    expect(WebMock).not_to have_requested(:post, /stripe\.com/)
  end

  it "records checkout completion and its subscription identity without inventing an event or entitlement" do
    row = attempt
    stub_checkout(row, status: "complete", subscription: "sub_completed")
    runner = recovery("checkouts")
    expect(runner.execute(runner.plan, max_requests: 1)).to include(failed: false)
    expect(row.reload).to have_attributes(status: "complete", stripe_subscription_id: "sub_completed")
    expect(row.class.unresolved_completed).to include(row)
    expect(BillingEvent.count).to eq(0)
    expect(Subscription.count).to eq(0)
    expect(PlanCatalog.for_user(user)).to eq("free")
    expect { Billing::HostedSessions.checkout(user:, interval: "month", request_id: SecureRandom.uuid) }
      .to raise_error(Billing::HostedSessions::Conflict) { |error| expect(error.code).to eq("CHECKOUT_PENDING_CONFIRMATION") }
    expect(WebMock).not_to have_requested(:get, /subscriptions/)
  end

  it "quarantines mismatched checkout identity, permits targeted review and never looks up unknown session IDs" do
    row = attempt
    unknown = attempt(stripe_id: nil, status: "needs_review")
    stub_checkout(row, customer: "cus_other")
    runner = recovery("checkouts")
    expect(runner.execute(runner.plan, max_requests: 1)).to include(failed: true)
    expect(row.reload.status).to eq("needs_review")
    row.update!(updated_at: 20.minutes.ago)
    runner = recovery("checkouts", ids: [ row.id, unknown.id ], include_review: true)
    expect(runner.plan.items.map(&:id)).to eq([ row.id ])
    stub_checkout(row)
    expect(runner.execute(runner.plan, max_requests: 1)).to include(failed: false)
    expect(row.reload.status).to eq("expired")
    expect(unknown.reload.status).to eq("needs_review")
    expect(WebMock).not_to have_requested(:get, %r{/v1/customers})
  end

  it "leaves a checkout unchanged on a timeout and reports the failed attempt without retrying" do
    row = attempt
    stub_request(:get, "https://api.stripe.com/v1/checkout/sessions/#{row.stripe_id}").to_timeout
    runner = recovery("checkouts")
    expect(runner.execute(runner.plan, max_requests: 1)).to include(provider_requests: 1, failed: true)
    expect(row.reload).to have_attributes(status: "open", updated_at: 20.minutes.ago)
    expect(WebMock).to have_requested(:get, "https://api.stripe.com/v1/checkout/sessions/#{row.stripe_id}").once
  end

  it "preserves the exact subscription identity during review instead of clearing billing safeguards" do
    row = attempt(status: "needs_review", stripe_subscription_id: "sub_retained")
    stub_checkout(row, subscription: "sub_other")
    runner = recovery("checkouts", ids: [ row.id ], include_review: true)
    expect(runner.execute(runner.plan, max_requests: 1)).to include(failed: true)
    expect(row.reload).to have_attributes(status: "needs_review", stripe_subscription_id: "sub_retained")
    expect(PlanCatalog.for_user(user)).to eq("free")
  end

  it "keeps associated subscription billing unresolved even when the provider returns an expired session" do
    row = attempt
    stub_checkout(row, subscription: "sub_retained")
    runner = recovery("checkouts")
    expect(runner.execute(runner.plan, max_requests: 1)).to include(failed: false)
    expect(row.reload).to have_attributes(status: "expired", stripe_subscription_id: "sub_retained")
    expect { Billing::HostedSessions.checkout(user:, interval: "month", request_id: SecureRandom.uuid) }
      .to raise_error(Billing::HostedSessions::Conflict) { |error| expect(error.code).to eq("CHECKOUT_PENDING_CONFIRMATION") }
    expect(Subscription.count).to eq(0)
    expect(WebMock).not_to have_requested(:post, /stripe\.com/)
  end

  it "never reopens a completed session when recovering its missing subscription reference" do
    row = attempt(status: "complete")
    stub_checkout(row, status: "open")
    runner = recovery("checkouts")
    expect(runner.execute(runner.plan, max_requests: 1)).to include(failed: true)
    expect(row.reload.status).to eq("needs_review")
    expect(WebMock).not_to have_requested(:post, /stripe\.com/)
  end

  it "revalidates changed records and ownership before executing the original plan" do
    receipt = event
    checkout = attempt
    events = recovery
    checkouts = recovery("checkouts")
    event_plan, checkout_plan = events.plan, checkouts.plan
    receipt.update!(status: "processed")
    other = create(:user, email_address: "recovery-other@example.com")
    customer.update!(user: other)
    expect(events.execute(event_plan, max_requests: 1)).to include(provider_requests: 0)
    expect(checkouts.execute(checkout_plan, max_requests: 1)).to include(provider_requests: 0)
    expect(checkout.reload.status).to eq("open")
    expect(WebMock).not_to have_requested(:any, /stripe\.com/)
  end

  it "bounds selected rows, respects mode and rejects malformed options" do
    first = event
    event(id: "evt_second")
    live = event(id: "evt_live")
    live.update!(livemode: true)
    expect(recovery(limit: 1).plan.items.map(&:id)).to eq([ first.id ])
    expect(recovery(ids: [ live.id ]).plan.items).to be_empty
    [ { limit: 0 }, { limit: 101 }, { ids: [ "1" ] }, { min_age_minutes: 0 }, { kind: "other" } ].each do |options|
      expect { described_class.new(kind: "events", **options) }.to raise_error(described_class::InvalidOptions)
    end
  end
end
