# frozen_string_literal: true

require "rails_helper"

RSpec.describe PasswordRecovery, type: :model do
  self.use_transactional_tests = false

  it "allows only one concurrent consumer to reset credentials with the same token" do
    user = create(:user, email_address: "recovery-concurrency@example.com")
    user.sessions.create!
    token = user.password_reset_token
    threads = 4.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          described_class.reset(token:, password: "replacement123", password_confirmation: "replacement123")
          :reset
        rescue described_class::InvalidToken
          :rejected
        end
      end
    end
    expect(threads.map(&:value).tally).to eq(reset: 1, rejected: 3)
    expect(user.sessions.count).to eq(0)
  ensure
    threads&.each(&:join)
    user&.destroy!
  end
end
