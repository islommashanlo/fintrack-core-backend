# frozen_string_literal: true

require "rails_helper"

RSpec.describe AlertRuleControl, type: :model do
  self.use_transactional_tests = false

  it "admits only three concurrent Free rule creations using committed database row locks" do
    user = User.create!(email_address: "alert-concurrency@example.com", password: "password123")
    follows = 4.times.map { |i| user.follows.create!(target_type: "Ticker", target_key: "CONCURRENT#{i}", skip_default_alert_rule: true) }
    threads = follows.map do |follow|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          described_class.create(user: User.find(user.id), follow_id: follow.id, attributes: { active: false })
          :created
        rescue PlanCatalog::Required
          :limited
        end
      end
    end
    results = threads.map(&:value)
    expect(results.count(:created)).to eq(3)
    expect(results.count(:limited)).to eq(1)
    expect(user.alert_rules.retained.count).to eq(3)
  ensure
    threads&.each(&:join)
    if user
      AccountNotificationCleanup.call(user)
      user.destroy!
    end
  end

  it "claims one digest and one item when multiple workers plan the same user's day" do
    user = User.create!(email_address: "digest-concurrency@example.com", password: "password123")
    consent_email(user)
    rule = enable_rule(user.follows.create!(target_type: "Ticker", target_key: "ACME").alert_rule)
    delivery = create(:alert_delivery, alert_rule: rule, frequency: "daily_digest")
    as_of = 2.days.from_now.change(hour: 12, min: 0, sec: 0)
    threads = 4.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          AlertDigestPlanner.call(user: User.find(user.id), as_of:).id
        end
      end
    end
    expect(threads.map(&:value).uniq.length).to eq(1)
    expect(user.alert_digest_batches.count).to eq(1)
    expect(AlertDigestItem.where(alert_delivery_id: delivery.id).count).to eq(1)
  ensure
    threads&.each(&:join)
    if user
      AccountNotificationCleanup.call(user)
      user.destroy!
    end
    Filing.find_by(id: delivery&.filing_id)&.destroy!
  end
end
