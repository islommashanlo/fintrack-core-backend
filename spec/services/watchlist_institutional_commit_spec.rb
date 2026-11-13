# frozen_string_literal: true

require "rails_helper"

RSpec.describe WatchlistInstitutionalMatcher do
  include InstitutionalAlertHelpers
  self.use_transactional_tests = false

  it "defers jobs to commit and recovers enqueue failure without extending captured fund evidence" do
    user = create(:user, email_address: "institutional-commit@example.com")
    consent_email(user)
    fund = create(:institutional_filer)
    create(:follow, user:, target_type: "InstitutionalFiler", target_key: fund.cik,
      followed_at: 1.year.ago, skip_default_alert_rule: true)
    rule = user.alert_rules.create!(scope: "watchlist", event_type: "13f_change", channel: "email", active: true)
    rule.setting.update!(frequency: "instant", enabled_at: 1.year.ago)
    prior, current = alert_pair(fund:)
    allow(SendAlertJob).to receive(:perform_later).and_return(true)
    ApplicationRecord.transaction do
      described_class.call(current.filing, channel: "email")
      expect(SendAlertJob).not_to have_received(:perform_later)
      raise ActiveRecord::Rollback
    end
    expect(user.alert_deliveries.count).to eq(0)
    expect(WatchlistFilingMembership.where(user_id: user.id).count).to eq(0)
    ApplicationRecord.transaction do
      described_class.call(current.filing, channel: "email")
      expect(SendAlertJob).not_to have_received(:perform_later)
    end
    delivery = user.alert_deliveries.sole
    expect(SendAlertJob).to have_received(:perform_later).with(delivery.id).once
    witness = WatchlistFilingMembership.find_by!(alert_delivery_id: delivery.id).attributes
    allow(SendAlertJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError)
    expect { described_class.call(current.filing, channel: "email") }.to raise_error(ActiveJob::EnqueueError)
    allow(SendAlertJob).to receive(:perform_later).and_return(false)
    expect { described_class.call(current.filing, channel: "email") }.to raise_error(ActiveJob::EnqueueError)
    allow(SendAlertJob).to receive(:perform_later).and_return(true)
    described_class.call(current.filing, channel: "email")
    expect(user.alert_deliveries.count).to eq(1)
    expect(WatchlistFilingMembership.find(witness.fetch("id")).attributes).to eq(witness)
  ensure
    if user
      AccountNotificationCleanup.call(user)
      user.destroy!
    end
    InstitutionalChangeSnapshot.where(institutional_filer_id: fund.id).delete_all if fund
    [ prior, current ].compact.each do |report|
      report.institutional_holdings.destroy_all
      report.destroy!
      report.filing.reload.destroy!
    end
    fund&.destroy!
  end
end
