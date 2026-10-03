# frozen_string_literal: true

require "rails_helper"

RSpec.describe SendAlertJob do
  it "sends a filing alert and is idempotent when run again" do
    delivery = create(:alert_delivery)

    expect do
      described_class.perform_now(delivery.id)
    end.to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(delivery.reload).to have_attributes(status: "sent")
    expect { described_class.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.size }
  end

  it "records a failed delivery before retrying the job" do
    delivery = create(:alert_delivery)
    allow(FilingAlertMailer).to receive(:new_filing).and_raise(StandardError, "mail transport unavailable")

    expect { described_class.perform_now(delivery.id) }.to raise_error(StandardError, "mail transport unavailable")

    expect(delivery.reload).to have_attributes(status: "failed", error: "StandardError: mail transport unavailable")
  end
end
