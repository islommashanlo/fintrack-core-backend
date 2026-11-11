# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProcessStripeEventJob do
  around { |example| with_billing_config { example.run } }

  it "retries transient failures and caps automatic attempts at four executions" do
    user = create(:user)
    bind_billing_customer(user)
    body = stripe_event_body
    event = Billing::ReceiveEvent.call(attributes: Billing::StripeEvent.parse(body), payload_digest: Digest::SHA256.hexdigest(body)).event
    clear_enqueued_jobs
    stub_subscription(status: 503)
    job = described_class.new(event.id)
    3.times do
      expect { job.perform_now }.to have_enqueued_job(described_class).with(event.id)
      expect(event.reload.status).to eq("failed")
      clear_enqueued_jobs
    end
    expect { job.perform_now }.not_to have_enqueued_job(described_class)
    expect(event.reload.attempts).to eq(4)
    expect(event.reload.reason).to eq("retries_exhausted")
  end
end
