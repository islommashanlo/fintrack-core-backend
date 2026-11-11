# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedScreenStore, type: :model do
  self.use_transactional_tests = false

  before do
    allow(PlanCatalog).to receive(:limit_for).and_call_original
    allow(PlanCatalog).to receive(:limit_for).with(anything, :saved_screens).and_return(true)
  end

  it "admits one name when concurrent requests create the same screen" do
    user = create(:user, email_address: "screen-concurrency@example.com")
    threads = 4.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          described_class.create(user: User.find(user.id), attributes: { name: "Example", definition: { "entity" => "funds" } })
          :created
        rescue ActiveRecord::RecordInvalid
          :duplicate
        end
      end
    end
    expect(threads.map(&:value).tally).to eq(created: 1, duplicate: 3)
    expect(user.saved_screens.count).to eq(1)
  ensure
    threads&.each(&:join)
    user&.destroy!
  end

  it "preserves independent metadata and definition updates from concurrent clients" do
    user = create(:user, email_address: "screen-update-concurrency@example.com")
    screen = user.saved_screens.create!(name: "Example", entity: "companies", window_days: 90)
    changes = [ { name: "Renamed" }, { definition: { "entity" => "funds" } } ]
    threads = changes.map do |attributes|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          described_class.update(user: User.find(user.id), id: screen.id, attributes:)
        end
      end
    end
    threads.each(&:value)
    expect(screen.reload).to have_attributes(name: "Renamed", entity: "funds", window_days: nil)
  ensure
    threads&.each(&:join)
    user&.destroy!
  end
end
