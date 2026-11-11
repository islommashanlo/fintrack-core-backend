# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccountPreferences, type: :model do
  self.use_transactional_tests = false

  it "serializes concurrent first-time partial updates without duplicate rows or lost fields" do
    user = create(:user, email_address: "preference-concurrency@example.com")
    changes = [ { theme: "dark" }, { dashboard_layout: "focus" } ]
    threads = changes.map do |attributes|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          described_class.update(user: User.find(user.id), attributes:).id
        end
      end
    end
    expect(threads.map(&:value).uniq.size).to eq(1)
    expect(UserPreference.where(user:).count).to eq(1)
    expect(user.reload.user_preference).to have_attributes(theme: "dark", dashboard_layout: "focus")
  ensure
    threads&.each(&:join)
    user&.destroy!
  end
end
