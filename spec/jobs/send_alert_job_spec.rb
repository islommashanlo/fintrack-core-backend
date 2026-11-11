# frozen_string_literal: true

require "rails_helper"

RSpec.describe SendAlertJob do
  before do
    allow(PlanCatalog).to receive(:limit_for).and_call_original
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
  end

  def sendable_delivery
    delivery = create(:alert_delivery)
    consent_email(delivery.alert_rule.follow.user)
    enable_rule(delivery.alert_rule, frequency: "instant")
    delivery
  end

  it "sends a filing alert and is idempotent when run again" do
    delivery = sendable_delivery

    expect do
      described_class.perform_now(delivery.id)
    end.to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(delivery.reload).to have_attributes(status: "sent")
    expect { described_class.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.size }
  end

  it "records a failed delivery before retrying the job" do
    delivery = sendable_delivery
    allow(FilingAlertMailer).to receive(:new_filing).and_raise(StandardError, "mail transport unavailable")

    expect { described_class.perform_now(delivery.id) }.to raise_error(StandardError, "mail transport unavailable")

    expect(delivery.reload).to have_attributes(status: "failed", error: "StandardError: mail transport unavailable")
  end

  it "does not send queued mail after its rule is paused and retains pending history" do
    delivery = sendable_delivery
    delivery.alert_rule.update!(active: false)

    expect { described_class.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.size }
    expect(delivery.reload).to have_attributes(status: "pending", delivered_at: nil, error: nil)
  end
end
