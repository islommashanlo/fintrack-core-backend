# frozen_string_literal: true

require "rails_helper"

RSpec.describe WatchlistMembership, type: :model do
  # Separate database connections must see committed rows for a real lock race.
  self.use_transactional_tests = false

  it "admits only one concurrent addition when fourteen Free watchlist slots are occupied" do
    user = User.create!(email_address: "quota-concurrency@example.com", password: "password123")
    14.times { |i| user.follows.create!(target_type: "Ticker", target_key: "BASE#{i}", skip_default_alert_rule: true) }
    threads = 4.times.map do |i|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          target = FollowTarget::Target.new("Ticker", "CONCURRENT#{i}", "Example #{i}")
          described_class.add(user: User.find(user.id), target:)
          :created
        rescue PlanCatalog::Required
          :limited
        end
      end
    end
    results = threads.map(&:value)
    expect(results.count(:created)).to eq(1)
    expect(results.count(:limited)).to eq(3)
    expect(user.follows.count).to eq(15)
    expect(user.alert_rules.count).to eq(0)
  ensure
    threads&.each(&:join)
    user&.destroy!
  end
end
