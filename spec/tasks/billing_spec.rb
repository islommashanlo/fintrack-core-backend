# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "Billing recovery tasks" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("billing:recover_events") }
  around do |example|
    keys = %w[IDS INCLUDE_REVIEW LIMIT MIN_AGE_MINUTES CONFIRM MAX_REQUESTS]
    previous = ENV.to_h.slice(*keys)
    keys.each { |key| ENV.delete(key) }
    with_billing_config { example.run }
  ensure
    keys.each { |key| previous.key?(key) ? ENV[key] = previous.fetch(key) : ENV.delete(key) }
  end

  def run_task(name)
    output, errors = StringIO.new, StringIO.new
    previous_out, previous_err = $stdout, $stderr
    $stdout, $stderr = output, errors
    task = Rake::Task[name]
    task.reenable
    task.invoke
    [ output.string, errors.string, 0 ]
  rescue SystemExit => error
    [ output.string, errors.string, error.status ]
  ensure
    $stdout, $stderr = previous_out, previous_err
  end

  def checkout
    user = create(:user)
    customer = bind_billing_customer(user)
    user.billing_checkouts.create!(billing_customer: customer, livemode: false, request_id: SecureRandom.uuid,
      interval: "month", price_id: "price_fixture_pro", stripe_id: "cs_task", status: "open",
      success_url: "https://app.example.com/billing", cancel_url: "https://app.example.com/billing", updated_at: 20.minutes.ago)
  end

  it "defaults to a read-only preview with request counts and no queued jobs" do
    row = checkout
    before = row.attributes
    output, errors, status = run_task("billing:recover_checkouts")
    expect(status).to eq(0)
    expect(errors).to be_empty
    expect(output).to include('"selected_count":1', '"max_provider_requests":1', "Dry run: 0 provider requests")
    expect(row.reload.attributes).to eq(before)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:any, /stripe\.com/)
  end

  it "requires confirmation and a sufficient explicit request budget before any writes or requests" do
    row = checkout
    ENV["CONFIRM"] = "recover"
    expect(run_task("billing:recover_checkouts").last).to eq(1)
    ENV["MAX_REQUESTS"] = "0"
    expect(run_task("billing:recover_checkouts").last).to eq(1)
    expect(row.reload.status).to eq("open")
    expect(WebMock).not_to have_requested(:any, /stripe\.com/)
  end

  it "executes only the selected known checkout with one mocked GET" do
    row = checkout
    ENV.update("CONFIRM" => "recover", "MAX_REQUESTS" => "1", "IDS" => row.id.to_s)
    data = { id: row.stripe_id, object: "checkout.session", customer: "cus_fixture", mode: "subscription",
      livemode: false, client_reference_id: row.request_id, status: "expired", expires_at: 1.minute.ago.to_i }
    stub_request(:get, "https://api.stripe.com/v1/checkout/sessions/cs_task").to_return(status: 200, body: data.to_json)
    output, errors, status = run_task("billing:recover_checkouts")
    expect(status).to eq(0)
    expect(errors).to be_empty
    expect(output).to include('"provider_requests":1', '"status":"expired"')
    expect(output).not_to include("cus_fixture", "cs_task", "https://", "sk_test_fixture")
    expect(row.reload.status).to eq("expired")
    expect(WebMock).not_to have_requested(:post, /stripe\.com/)
  end

  it "reports failed recovery through a nonzero exit without provider error contents" do
    row = checkout
    ENV.update("CONFIRM" => "recover", "MAX_REQUESTS" => "1")
    stub_request(:get, "https://api.stripe.com/v1/checkout/sessions/cs_task").to_return(status: 503, body: "provider secret detail")
    output, errors, status = run_task("billing:recover_checkouts")
    expect(status).to eq(1)
    expect(output).to include('"status":"failed"')
    expect(errors).to include("failed/review items")
    expect(output + errors).not_to include("provider secret detail")
    expect(row.reload.status).to eq("open")
  end

  it "rejects invalid bounds, malformed IDs and untargeted review; disabled billing is preview-only" do
    [ { "LIMIT" => "101" }, { "MIN_AGE_MINUTES" => "0" }, { "IDS" => "1,no" }, { "INCLUDE_REVIEW" => "1" } ].each do |values|
      ENV.update(values)
      expect(run_task("billing:recover_events").last).to eq(1)
      values.each_key { |key| ENV.delete(key) }
    end
    ENV["STRIPE_BILLING_MODE"] = "off"
    output, _, status = run_task("billing:recover_events")
    expect(status).to eq(0)
    expect(output).to include('"mode":"off"', '"max_provider_requests":0')
    ENV.update("CONFIRM" => "recover", "MAX_REQUESTS" => "0")
    expect(run_task("billing:recover_events").last).to eq(1)
    expect(WebMock).not_to have_requested(:any, /stripe\.com/)
  end
end
