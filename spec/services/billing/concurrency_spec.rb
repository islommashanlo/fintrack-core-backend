# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Billing concurrency", type: :model do
  self.use_transactional_tests = false
  around { |example| with_billing_config { example.run } }

  it "stores one receipt and performs one provider refresh for concurrent duplicate deliveries" do
    user = create(:user, email_address: "billing-concurrency@example.com")
    customer = bind_billing_customer(user)
    body = stripe_event_body(id: "evt_concurrency")
    attributes = Billing::StripeEvent.parse(body)
    threads = 4.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Billing::ReceiveEvent.call(attributes:, payload_digest: Digest::SHA256.hexdigest(body)).event.id
        end
      end
    end
    ids = threads.map(&:value)
    expect(ids.uniq.size).to eq(1)
    stub_subscription
    threads = 4.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection { Billing::ProcessEvent.call(ids.first) }
      end
    end
    threads.each(&:value)
    expect(Subscription.where(billing_customer: customer).count).to eq(1)
    expect(WebMock).to have_requested(:get, "https://api.stripe.com/v1/subscriptions/sub_fixture").once
  ensure
    threads&.each(&:join)
    Subscription.where(billing_customer_id: customer.id).delete_all if customer
    BillingEvent.where(stripe_id: "evt_concurrency").delete_all
    customer&.destroy!
    user&.destroy!
  end
end
