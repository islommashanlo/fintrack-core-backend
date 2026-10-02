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
end
