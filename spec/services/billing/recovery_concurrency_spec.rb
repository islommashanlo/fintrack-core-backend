# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Concurrent billing recovery", type: :model do
  self.use_transactional_tests = false
  around { |example| with_billing_config { example.run } }

  it "retrieves one known checkout when operators execute the same stale plan concurrently" do
    user = create(:user, email_address: "recovery-concurrency@example.com")
    customer = bind_billing_customer(user)
    row = user.billing_checkouts.create!(billing_customer: customer, livemode: false, request_id: SecureRandom.uuid,
      interval: "month", price_id: "price_fixture_pro", stripe_id: "cs_concurrent_recovery", status: "open",
      success_url: "https://app.example.com/billing", cancel_url: "https://app.example.com/billing",
      expires_at: Time.at(1.hour.from_now.to_i).utc, updated_at: 20.minutes.ago)
    payload = { id: row.stripe_id, object: "checkout.session", customer: customer.stripe_id, livemode: false,
      mode: "subscription", client_reference_id: row.request_id, status: "open", expires_at: row.expires_at.to_i }
    stub_request(:get, "https://api.stripe.com/v1/checkout/sessions/#{row.stripe_id}").to_return(status: 200, body: payload.to_json)
    runner = Billing::Recovery.new(kind: "checkouts")
    plan = runner.plan
    threads = 4.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection { runner.execute(plan, max_requests: 1) }
      end
    end
    results = threads.map(&:value)
    expect(results.sum { |result| result.fetch(:provider_requests) }).to eq(1)
    expect(row.reload.status).to eq("open")
    expect(PlanCatalog.for_user(user)).to eq("free")
    expect(WebMock).to have_requested(:get, "https://api.stripe.com/v1/checkout/sessions/#{row.stripe_id}").once
    expect(WebMock).not_to have_requested(:post, /stripe\.com/)
  ensure
    threads&.each(&:join)
    user&.destroy!
    customer&.destroy!
  end
end
