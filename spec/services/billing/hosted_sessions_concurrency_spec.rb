# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::HostedSessions, type: :model do
  self.use_transactional_tests = false
  around { |example| with_billing_config { example.run } }

  it "creates a single customer and hosted checkout for simultaneous retries" do
    user = create(:user, email_address: "checkout-concurrency@example.com")
    request_id = SecureRandom.uuid
    stub_request(:post, "https://api.stripe.com/v1/customers").to_return(status: 200,
      body: { id: "cus_fixture", object: "customer", livemode: false }.to_json)
    payload = { id: "cs_test_fixture", object: "checkout.session", customer: "cus_fixture", livemode: false,
      mode: "subscription", client_reference_id: request_id, status: "open", expires_at: 30.minutes.from_now.to_i,
      url: "https://checkout.stripe.com/c/pay/cs_test_fixture" }.to_json
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions").to_return(status: 200, body: payload)
    stub_request(:get, "https://api.stripe.com/v1/checkout/sessions/cs_test_fixture").to_return(status: 200, body: payload)
    threads = 4.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          described_class.checkout(user: User.find(user.id), interval: "month", request_id:)
        end
      end
    end
    expect(threads.map(&:value).map { |result| result.fetch(:url) }.uniq.size).to eq(1)
    expect(user.billing_checkouts.count).to eq(1)
    expect(user.billing_customers.count).to eq(1)
    expect(WebMock).to have_requested(:post, "https://api.stripe.com/v1/customers").once
    expect(WebMock).to have_requested(:post, "https://api.stripe.com/v1/checkout/sessions").once
  ensure
    threads&.each(&:join)
    customer_ids = BillingCustomer.where(user_id: user.id).pluck(:id) if user
    user&.destroy!
    BillingCustomer.where(id: customer_ids).destroy_all if customer_ids
  end
end
