# frozen_string_literal: true

require "rails_helper"

RSpec.describe WatchlistFilingEmailMatcher do
  self.use_transactional_tests = false

  it "defers instant jobs to commit, drops rollbacks and recovers a queue outage without rewriting witnesses" do
    user = create(:user, email_address: "email-commit@example.com")
    consent_email(user)
    create(:follow, user:, skip_default_alert_rule: true)
    rule = user.alert_rules.create!(scope: "watchlist", event_type: "new_filing", channel: "email", active: true)
    rule.setting.update!(frequency: "instant", enabled_at: 1.day.ago)
    filing = create(:filing, issuer_ticker: "ACME", filed_at: Time.current)
    allow(SendAlertJob).to receive(:perform_later).and_return(true)
    ApplicationRecord.transaction do
      described_class.call(filing)
      expect(SendAlertJob).not_to have_received(:perform_later)
      raise ActiveRecord::Rollback
    end
    expect(user.alert_deliveries.count).to eq(0)
    expect(WatchlistFilingMembership.where(user_id: user.id).count).to eq(0)
    ApplicationRecord.transaction do
      described_class.call(filing)
      expect(SendAlertJob).not_to have_received(:perform_later)
    end
    delivery = user.alert_deliveries.sole
    expect(SendAlertJob).to have_received(:perform_later).with(delivery.id).once
    witness = WatchlistFilingMembership.find_by!(alert_delivery_id: delivery.id).attributes
    allow(SendAlertJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError)
    expect { described_class.call(filing) }.to raise_error(ActiveJob::EnqueueError)
    allow(SendAlertJob).to receive(:perform_later).and_return(false)
    expect { described_class.call(filing) }.to raise_error(ActiveJob::EnqueueError)
    allow(SendAlertJob).to receive(:perform_later).and_return(true)
    described_class.call(filing)
    expect(user.alert_deliveries.count).to eq(1)
    expect(WatchlistFilingMembership.find(witness.fetch("id")).attributes).to eq(witness)
  ensure
    if user
      AccountNotificationCleanup.call(user)
      user.destroy!
    end
    filing&.destroy!
  end
end
