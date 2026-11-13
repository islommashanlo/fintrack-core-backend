# frozen_string_literal: true

require "rails_helper"

RSpec.describe WatchlistFilingEmailMatcher do
  self.use_transactional_tests = false

  %w[new_filing insider_transaction cluster].each do |event_type|
    it "defers #{event_type} jobs to commit and recovers queue outages without rewriting witnesses" do
      user = create(:user, email_address: "email-commit@example.com")
      consent_email(user)
      create(:follow, user:, skip_default_alert_rule: true)
      rule = user.alert_rules.create!(scope: "watchlist", event_type:, channel: "email", active: true)
      rule.setting.update!(frequency: "instant", enabled_at: 1.day.ago)
      filing = create(:filing, issuer_ticker: "ACME", filed_at: Time.current)
      transaction_rows = case event_type
      when "insider_transaction" then [ create(:insider_transaction, filing:) ]
      when "cluster" then 3.times.map { |i| create(:insider_transaction, filing:, insider_cik: format("%010d", 901 + i)) }
      else []
      end
      capture = lambda do
        case event_type
        when "new_filing" then described_class.call(filing)
        when "insider_transaction" then WatchlistTransactionMatcher.call(filing, channel: "email")
        when "cluster" then WatchlistClusterMatcher.call(filing, channel: "email")
        end
      end
      allow(SendAlertJob).to receive(:perform_later).and_return(true)
      ApplicationRecord.transaction do
        capture.call
        expect(SendAlertJob).not_to have_received(:perform_later)
        raise ActiveRecord::Rollback
      end
      expect(user.alert_deliveries.count).to eq(0)
      expect(WatchlistFilingMembership.where(user_id: user.id).count).to eq(0)
      ApplicationRecord.transaction do
        capture.call
        expect(SendAlertJob).not_to have_received(:perform_later)
      end
      delivery = user.alert_deliveries.sole
      expect(SendAlertJob).to have_received(:perform_later).with(delivery.id).once
      witness = WatchlistFilingMembership.find_by!(alert_delivery_id: delivery.id).attributes
      allow(SendAlertJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError)
      expect { capture.call }.to raise_error(ActiveJob::EnqueueError)
      allow(SendAlertJob).to receive(:perform_later).and_return(false)
      expect { capture.call }.to raise_error(ActiveJob::EnqueueError)
      allow(SendAlertJob).to receive(:perform_later).and_return(true)
      capture.call
      expect(user.alert_deliveries.count).to eq(1)
      expect(WatchlistFilingMembership.find(witness.fetch("id")).attributes).to eq(witness)
    ensure
      if user
        AccountNotificationCleanup.call(user)
        user.destroy!
      end
      InsiderClusterSnapshot.where(primary_filing_id: filing.id).delete_all if filing
      transaction_rows&.each(&:destroy!)
      filing&.destroy!
    end
  end
end
