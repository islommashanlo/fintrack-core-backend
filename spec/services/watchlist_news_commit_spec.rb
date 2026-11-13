# frozen_string_literal: true

require "rails_helper"

RSpec.describe WatchlistNewsMatcher do
  self.use_transactional_tests = false
  before { approve_fixture_news }

  it "defers news jobs until commit and recovers outages without rewriting mention evidence" do
    user = create(:user, email_address: "news-commit@example.com")
    consent_email(user)
    fund = create(:institutional_filer)
    create(:follow, user:, target_type: "InstitutionalFiler", target_key: fund.cik,
      followed_at: 1.year.ago, skip_default_alert_rule: true)
    rule = user.alert_rules.create!(scope: "watchlist", event_type: "news", channel: "email", active: true)
    rule.setting.update!(frequency: "instant", enabled_at: 1.year.ago)
    item = store_news(entities: [ News::Entity.new(role: "fund", id: fund.id) ])
    allow(SendAlertJob).to receive(:perform_later).and_return(true)
    ApplicationRecord.transaction do
      described_class.call(item, channel: "email")
      expect(SendAlertJob).not_to have_received(:perform_later)
      raise ActiveRecord::Rollback
    end
    expect(user.alert_deliveries.count).to eq(0)
    expect(WatchlistNewsMembership.where(user_id: user.id).count).to eq(0)
    ApplicationRecord.transaction do
      described_class.call(item, channel: "email")
      expect(SendAlertJob).not_to have_received(:perform_later)
    end
    delivery = user.alert_deliveries.sole
    expect(SendAlertJob).to have_received(:perform_later).with(delivery.id).once
    proof = WatchlistNewsMembership.find_by!(alert_delivery_id: delivery.id).attributes
    allow(SendAlertJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError)
    expect { described_class.call(item, channel: "email") }.to raise_error(ActiveJob::EnqueueError)
    allow(SendAlertJob).to receive(:perform_later).and_return(false)
    expect { described_class.call(item, channel: "email") }.to raise_error(ActiveJob::EnqueueError)
    allow(SendAlertJob).to receive(:perform_later).and_return(true)
    described_class.call(item, channel: "email")
    expect(user.alert_deliveries.count).to eq(1)
    expect(WatchlistNewsMembership.find(proof.fetch("id")).attributes).to eq(proof)
  ensure
    if user
      AccountNotificationCleanup.call(user)
      user.destroy!
    end
    if item
      NewsAlertSnapshot.where(news_item_id: item.id).delete_all
      item.news_mentions.destroy_all
      item.reload.destroy!
    end
    fund&.destroy!
  end
end
