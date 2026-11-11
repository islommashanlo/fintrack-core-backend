# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::ProcessEvent do
  around { |example| with_billing_config { travel_to(Time.utc(2026, 11, 11, 3)) { example.run } } }
  let(:user) { create(:user) }
  before { bind_billing_customer(user) }

  def receipt(id: "evt_fixture", **options)
    body = stripe_event_body(id:, **options)
    Billing::ReceiveEvent.call(attributes: Billing::StripeEvent.parse(body), payload_digest: Digest::SHA256.hexdigest(body)).event
  end

  %w[active trialing past_due canceled unpaid paused incomplete incomplete_expired].each do |status|
    it "derives #{status} access from a current provider snapshot rather than browser state" do
      snapshot = billing_snapshot(status:, trial_end: status == "trialing" ? 7.days.from_now.to_i : nil)
      event = apply_billing_event(snapshot:)
      expect(event.status).to eq("processed")
      expect(Subscription.sole.status).to eq(status)
      expect(PlanCatalog.for_user(user)).to eq(%w[active trialing].include?(status) ? "pro" : "free")
      expect(PlanCatalog.for_user(nil)).to eq("free")
    end
  end

  it "expires access at period, trial and explicit cancellation boundaries without needing another webhook" do
    apply_billing_event
    expect(PlanCatalog.for_user(user)).to eq("pro")
    travel 29.days
    expect(PlanCatalog.for_user(user)).to eq("free")
    travel(-29.days)
    apply_billing_event(id: "evt_trial", snapshot: billing_snapshot(status: "trialing", trial_end: 1.hour.from_now.to_i))
    travel 1.hour
    expect(PlanCatalog.for_user(user)).to eq("free")
    travel(-1.hour)
    apply_billing_event(id: "evt_cancel_at", snapshot: billing_snapshot(cancel_at_period_end: true, cancel_at: 30.minutes.from_now.to_i))
    expect(PlanCatalog.for_user(user)).to eq("pro")
    travel 30.minutes
    expect(PlanCatalog.for_user(user)).to eq("free")
  end

  it "does not expire immediately when cancellation is scheduled for the period end" do
    apply_billing_event(snapshot: billing_snapshot(cancel_at_period_end: true))
    expect(PlanCatalog.for_user(user)).to eq("pro")
    expect(Subscription.sole.cancel_at_period_end).to be(true)
  end

  it "never infers the owner from webhook metadata or email for an unlinked customer" do
    snapshot = billing_snapshot(customer: "cus_unknown", metadata: { user_id: user.id, email: user.email_address })
    event = receipt(snapshot:)
    expect(Billing::StripeClient).not_to receive(:new)
    described_class.call(event.id, client: double)
    expect(event.reload).to have_attributes(status: "ignored", reason: "unmatched_customer")
    expect(Subscription.count).to eq(0)
    expect(PlanCatalog.for_user(user)).to eq("free")
  end

  it "refreshes current state for delayed and same-second events instead of sorting event timestamps" do
    early = receipt(id: "evt_early", created: 2.hours.ago.to_i)
    late = receipt(id: "evt_late", created: 1.hour.ago.to_i)
    stub_subscription(billing_snapshot(status: "past_due"))
    described_class.call(late.id)
    described_class.call(early.id)
    expect(Subscription.sole.status).to eq("past_due")
    expect(PlanCatalog.for_user(user)).to eq("free")
    same_second = receipt(id: "evt_same", created: 1.hour.ago.to_i)
    stub_subscription(billing_snapshot)
    described_class.call(same_second.id)
    expect(PlanCatalog.for_user(user)).to eq("pro")
    expect(WebMock).to have_requested(:get, "https://api.stripe.com/v1/subscriptions/sub_fixture").times(3)
    described_class.call(early.id)
    expect(WebMock).to have_requested(:get, "https://api.stripe.com/v1/subscriptions/sub_fixture").times(3)
  end

  it "applies a signed terminal deletion without retrieval and never resurrects that subscription" do
    apply_billing_event
    deletion = receipt(id: "evt_deleted", type: "customer.subscription.deleted", snapshot: billing_snapshot(status: "canceled"))
    client = double
    expect(client).not_to receive(:retrieve_subscription)
    described_class.call(deletion.id, client:)
    older = receipt(id: "evt_delayed", created: 1.hour.ago.to_i)
    described_class.call(older.id, client:)
    expect(Subscription.sole.status).to eq("canceled")
    expect(older.reload).to have_attributes(status: "ignored", reason: "terminal_subscription")
    expect(PlanCatalog.for_user(user)).to eq("free")
  end

  it "denies an unrecognized price and a paused collection even with active status" do
    snapshot = billing_snapshot
    snapshot.fetch("items").fetch("data").sole.fetch("price")["id"] = "price_unknown"
    apply_billing_event(snapshot:)
    expect(Subscription.sole.price_id).to eq("price_unknown")
    expect(PlanCatalog.for_user(user)).to eq("free")
    apply_billing_event(id: "evt_paused_collection", snapshot: billing_snapshot(pause_collection: { behavior: "void" }))
    expect(PlanCatalog.for_user(user)).to eq("free")
  end

  it "revokes entitlement and records review when the authoritative response is malformed" do
    apply_billing_event
    event = receipt(id: "evt_invalid")
    malformed = billing_snapshot
    malformed.fetch("items")["data"] = []
    stub_subscription(malformed)
    described_class.call(event.id)
    expect(event.reload).to have_attributes(status: "needs_review", reason: "invalid_provider_snapshot")
    expect(Subscription.sole.sync_status).to eq("needs_review")
    expect(PlanCatalog.for_user(user)).to eq("free")
    expect(OpsMetrics.new.to_h.fetch(:billing)).to include(needs_review: 1)
  end

  it "rejects legacy top-level periods and incomplete item lists instead of assuming their units or coverage" do
    event = receipt
    snapshot = billing_snapshot
    item = snapshot.fetch("items").fetch("data").sole
    snapshot["current_period_end"] = item.delete("current_period_end")
    stub_subscription(snapshot)
    described_class.call(event.id)
    expect(event.reload.status).to eq("needs_review")
    expect(Subscription.count).to eq(0)
  end

  it "rejects response identity and mode mismatches" do
    [ { customer: "cus_other" }, { id: "sub_other" }, { livemode: true } ].each_with_index do |changes, index|
      event = receipt(id: "evt_mismatch#{index}")
      snapshot = billing_snapshot(**changes)
      stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_fixture").to_return(status: 200, body: snapshot.to_json)
      described_class.call(event.id)
      expect(event.reload.status).to eq("needs_review")
    end
    expect(Subscription.count).to eq(0)
  end

  it "records transport failures for retry and makes subsequent success idempotent" do
    event = receipt
    stub_subscription(status: 503)
    expect { described_class.call(event.id) }.to raise_error(Billing::StripeClient::TransientError)
    expect(event.reload).to have_attributes(status: "failed", attempts: 1, reason: "provider_unavailable")
    stub_subscription
    described_class.call(event.id)
    expect(event.reload).to have_attributes(status: "processed", attempts: 2)
    expect { described_class.call(event.id) }.not_to change(Subscription, :count)
  end

  it "does not retry deterministic provider rejection" do
    event = receipt
    stub_subscription(status: 401)
    described_class.call(event.id)
    expect(event.reload.status).to eq("needs_review")
    expect(Subscription.count).to eq(0)
  end

  it "retains a failed receipt when provider credentials disappear before processing" do
    event = receipt
    ENV["STRIPE_SECRET_KEY"] = ""
    described_class.call(event.id)
    expect(event.reload).to have_attributes(status: "failed", reason: "configuration_unavailable")
    expect(WebMock).not_to have_requested(:get, /stripe\.com/)
  end

  it "prevents a test subscription from granting production access or a customer from being reassigned" do
    apply_billing_event
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    expect(PlanCatalog.for_user(user)).to eq("free")
    expect { Billing::Configuration.require_webhooks! }.to raise_error(Billing::Configuration::Unavailable)
    other = create(:user, email_address: "other@example.com")
    expect { bind_billing_customer(other) }.to raise_error(Billing::CustomerLink::Conflict)
  end

  it "preserves paid instant rules during legacy conversion while pausing Free rules" do
    apply_billing_event
    paid_rule = user.follows.create!(target_type: "Ticker", target_key: "PAID").alert_rule
    paid_rule.setting.update!(frequency: "instant")
    paid_rule.update_columns(active: true)
    other = create(:user, email_address: "other@example.com")
    free_rule = other.follows.create!(target_type: "Ticker", target_key: "FREE").alert_rule
    free_rule.setting.update!(frequency: "instant")
    free_rule.update_columns(active: true)
    LegacyAlertSettings.convert!
    expect(paid_rule.reload).to be_active
    expect(free_rule.reload).not_to be_active
  end

  it "suppresses queued instant delivery after verified paid access is lost" do
    apply_billing_event
    consent_email(user)
    rule = enable_rule(user.follows.create!(target_type: "Ticker", target_key: "PAID").alert_rule, frequency: "instant")
    delivery = create(:alert_delivery, alert_rule: rule, frequency: "instant")
    expect(AlertDeliveryPolicy.eligible?(delivery, user:, frequency: "instant")).to be(true)
    apply_billing_event(id: "evt_past_due", snapshot: billing_snapshot(status: "past_due"))
    expect(AlertDeliveryPolicy.eligible?(delivery, user:, frequency: "instant")).to be(false)
    expect(rule.reload).to be_active
  end
end
